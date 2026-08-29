import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TextInjectionEngine: @unchecked Sendable {

    enum ClipboardRetention: Sendable, Equatable {
        /// Keep the dictated result in the system clipboard after the paste attempt.
        case retainResult
        /// Restore the clipboard captured before the paste attempt, including
        /// when no editable target was found.
        case restoreOriginal
    }

    private struct FocusedElementSnapshot {
        let element: AXUIElement?
        let processIdentifier: pid_t?
        let bundleIdentifier: String?
        let role: String?
        let subrole: String?
        let value: String?
        let placeholder: String?
        let accessibilityDescription: String?
        let selectedRange: NSRange?
        let isEditable: Bool
        /// true when AX successfully found a focused UI element; false when
        /// no element was found (e.g. desktop, no focused window).
        let hasFocusedElement: Bool
    }

    typealias ClipboardSnapshot = Type4Me.ClipboardSnapshot

    // MARK: - Public

    /// Whether a normal paste attempt retains its result or restores the
    /// clipboard that existed before injection.
    var clipboardRetention: ClipboardRetention = .restoreOriginal

    /// Inject text into the currently focused input field.
    /// Returns the outcome as soon as the paste is dispatched.
    /// Call ``finishClipboardRestore()`` afterward to restore the original clipboard.
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        return injectViaClipboard(text, trackingMetadata: nil).outcome
    }

    /// Inject text while capturing enough Accessibility context to observe a
    /// later correction in the exact field Type4Me wrote into.
    func injectTracked(
        _ text: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID
    ) -> TrackedInjectionResult {
        guard !text.isEmpty else {
            return TrackedInjectionResult(outcome: .inserted, observationContext: nil)
        }
        return injectViaClipboard(
            text,
            trackingMetadata: (
                sourceText: sourceText,
                sourceRecordID: sourceRecordID,
                modeID: modeID
            )
        )
    }

    /// Restore the clipboard that was saved before injection.
    /// Safe to call even if there's nothing to restore.
    func finishClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        // Electron apps (VS Code, Slack, Notion, Feishu) may need 200-500ms
        // to read the clipboard after Cmd+V. 150ms (post-paste 100 + this 50)
        // was too fast. Bumped to 300ms here for ~400ms total.
        usleep(300_000)
        pending.snapshot.restore(expectedChangeCount: pending.changeCount)
    }

    /// Copy text to the system clipboard (used at session end).
    func copyToClipboard(_ text: String, transient: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if transient {
            pb.setData(Data(), forType: PasteboardHistoryPolicy.transientType)
        }
    }

    // MARK: - Clipboard injection

    private struct PendingClipboardRestore {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    private var pendingClipboardRestore: PendingClipboardRestore?

    private func injectViaClipboard(
        _ text: String,
        trackingMetadata: (sourceText: String, sourceRecordID: String, modeID: UUID)?
    ) -> TrackedInjectionResult {
        let shouldRestoreClipboard = clipboardRetention == .restoreOriginal
        let savedClipboard = shouldRestoreClipboard ? ClipboardSnapshot.capture() : nil

        // If Type4Me is frontmost, yield focus so the target application receives paste
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            DispatchQueue.main.sync {
                NSApp.hide(nil)
            }
            usleep(50_000)
        }

        // Snapshot focused element BEFORE paste for outcome detection
        let before = captureFocusedElementSnapshot()

        copyToClipboard(text, transient: shouldRestoreClipboard)
        let postWriteChangeCount = NSPasteboard.general.changeCount
        usleep(50_000)
        simulatePaste()
        usleep(100_000)

        // Snapshot AFTER paste and compare to detect if text landed
        let after = captureFocusedElementSnapshot()
        let detectedOutcome = inferInjectionOutcome(before: before, after: after, pastedText: text)
        let outcome = Self.finalizeOutcome(
            detectedOutcome,
            retention: clipboardRetention
        )

        // Defer restoration so the target app has time to consume Cmd+V.
        // Keep it pending for every result so a failed paste cannot leak text
        // into the clipboard under a restoring policy.
        if let savedClipboard {
            pendingClipboardRestore = PendingClipboardRestore(
                snapshot: savedClipboard, changeCount: postWriteChangeCount
            )
        } else {
            pendingClipboardRestore = nil
        }

        let context = trackingMetadata.flatMap { metadata in
            makeObservationContext(
                before: before,
                after: after,
                pastedText: text,
                sourceText: metadata.sourceText,
                sourceRecordID: metadata.sourceRecordID,
                modeID: metadata.modeID,
                outcome: outcome
            )
        }
        return TrackedInjectionResult(outcome: outcome, observationContext: context)
    }

    /// A restore policy cannot truthfully report a clipboard fallback: its
    /// temporary pasteboard contents are restored after the paste attempt.
    static func finalizeOutcome(
        _ detectedOutcome: InjectionOutcome,
        retention: ClipboardRetention
    ) -> InjectionOutcome {
        if detectedOutcome == .copiedToClipboard, retention == .restoreOriginal {
            return .notInserted
        }
        return detectedOutcome
    }

    private func simulatePaste() {
        let vKeyCode: CGKeyCode = 9 // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Set kAXEnhancedUserInterface on the frontmost app's focused window.
    /// This makes Electron/Chromium apps expose their full AX tree.
    private func enableEnhancedAX(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        AXUIElementSetAttributeValue(
            window,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    private func captureFocusedElementSnapshot() -> FocusedElementSnapshot? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier

        guard AXIsProcessTrusted() else {
            return FocusedElementSnapshot(
                element: nil,
                processIdentifier: frontmostApp?.processIdentifier,
                bundleIdentifier: frontmostBundleID,
                role: nil,
                subrole: nil,
                value: nil,
                placeholder: nil,
                accessibilityDescription: nil,
                selectedRange: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focusedValue: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        // AX blind (common with Electron apps). Enable enhanced AX and retry.
        if status != .success || focusedValue == nil, let frontmostApp {
            enableEnhancedAX(for: frontmostApp)
            usleep(30_000) // 30ms for Chromium to build AX tree
            status = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
        }

        // System-wide query still failed — try traversing the app's window tree
        // to find an editable element. Common for WeChat, Feishu, etc.
        if status != .success || focusedValue == nil, let frontmostApp {
            if let found = findEditableElementInApp(frontmostApp) {
                return snapshotFromElement(found, bundleIdentifier: frontmostBundleID)
            }
            return FocusedElementSnapshot(
                element: nil,
                processIdentifier: frontmostApp.processIdentifier,
                bundleIdentifier: frontmostBundleID,
                role: nil,
                subrole: nil,
                value: nil,
                placeholder: nil,
                accessibilityDescription: nil,
                selectedRange: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let element = unsafeDowncast(focusedValue!, to: AXUIElement.self)
        return snapshotFromElement(element, bundleIdentifier: frontmostBundleID)
    }

    private func snapshotFromElement(_ element: AXUIElement, bundleIdentifier: String?) -> FocusedElementSnapshot {
        AXUIElementSetMessagingTimeout(element, 0.5)
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
        let value = copyStringAttribute(kAXValueAttribute as CFString, from: element)
        let placeholder = copyStringAttribute(kAXPlaceholderValueAttribute as CFString, from: element)
        let accessibilityDescription = copyStringAttribute(kAXDescriptionAttribute as CFString, from: element)
        let selectedRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
        var processIdentifier: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &processIdentifier)
        let isEditable =
            isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ].contains(role)

        return FocusedElementSnapshot(
            element: element,
            processIdentifier: pidStatus == .success ? processIdentifier : nil,
            bundleIdentifier: bundleIdentifier,
            role: role,
            subrole: subrole,
            value: value,
            placeholder: placeholder,
            accessibilityDescription: accessibilityDescription,
            selectedRange: selectedRange,
            isEditable: isEditable,
            hasFocusedElement: true
        )
    }

    /// Traverse the app's focused window tree to find the first editable element.
    /// Used as fallback when system-wide kAXFocusedUIElementAttribute fails.
    private func findEditableElementInApp(_ app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return nil }

        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        return findEditableChild(in: window, maxDepth: 8)
    }

    private func findEditableChild(in element: AXUIElement, depth: Int = 0, maxDepth: Int) -> AXUIElement? {
        if depth > maxDepth { return nil }

        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        if editableRoles.contains(role ?? "") {
            return element
        }
        if isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element) {
            return element
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findEditableChild(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyRangeAttribute(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func makeObservationContext(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?,
        pastedText: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID,
        outcome: InjectionOutcome
    ) -> CorrectionObservationContext? {
        guard outcome == .inserted,
              let before,
              let after,
              before.hasFocusedElement,
              after.hasFocusedElement,
              before.isEditable,
              after.isEditable,
              let beforeElement = before.element,
              let afterElement = after.element,
              CFEqual(beforeElement, afterElement),
              let processIdentifier = after.processIdentifier,
              let bundleIdentifier = after.bundleIdentifier,
              let beforeValue = before.value,
              let afterValue = after.value,
              !isSecureTextRole(role: after.role, subrole: after.subrole),
              let insertedRange = inferInsertedRange(
                  beforeValue: beforeValue,
                  afterValue: afterValue,
                  selectedRange: before.selectedRange,
                  pastedText: pastedText
              )
        else { return nil }

        return CorrectionObservationContext(
            element: afterElement,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            baselineValue: afterValue,
            injectedRange: insertedRange,
            beforeSelectedRange: before.selectedRange,
            afterSelectedRange: after.selectedRange,
            placeholderCandidates: [
                before.placeholder,
                after.placeholder,
                before.accessibilityDescription,
                after.accessibilityDescription,
            ].compactMap { $0 },
            sourceText: sourceText,
            injectedText: pastedText,
            sourceRecordID: sourceRecordID,
            modeID: modeID
        )
    }

    private func isSecureTextRole(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }
    }

    private func inferInsertedRange(
        beforeValue: String,
        afterValue: String,
        selectedRange: NSRange?,
        pastedText: String
    ) -> NSRange? {
        let beforeNSString = beforeValue as NSString
        let afterNSString = afterValue as NSString
        let pastedLength = (pastedText as NSString).length

        if let selectedRange,
           NSMaxRange(selectedRange) <= beforeNSString.length {
            let expected = beforeNSString.replacingCharacters(in: selectedRange, with: pastedText)
            if expected == afterValue {
                return NSRange(location: selectedRange.location, length: pastedLength)
            }
        }

        var prefixLength = 0
        let sharedLength = min(beforeNSString.length, afterNSString.length)
        while prefixLength < sharedLength,
              beforeNSString.character(at: prefixLength) == afterNSString.character(at: prefixLength) {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < beforeNSString.length - prefixLength,
              suffixLength < afterNSString.length - prefixLength,
              beforeNSString.character(at: beforeNSString.length - suffixLength - 1)
                == afterNSString.character(at: afterNSString.length - suffixLength - 1) {
            suffixLength += 1
        }

        let changedAfterLength = afterNSString.length - prefixLength - suffixLength
        guard changedAfterLength == pastedLength else { return nil }
        let changedAfter = afterNSString.substring(
            with: NSRange(location: prefixLength, length: changedAfterLength)
        )
        guard changedAfter == pastedText else { return nil }
        return NSRange(location: prefixLength, length: pastedLength)
    }

    private func inferInjectionOutcome(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?,
        pastedText: String
    ) -> InjectionOutcome {
        DebugFileLogger.log("injection detect: before=\(before.map { "bundle=\($0.bundleIdentifier ?? "nil") role=\($0.role ?? "nil") editable=\($0.isEditable) hasFocus=\($0.hasFocusedElement) valueLength=\($0.value?.count ?? -1)" } ?? "nil")")
        DebugFileLogger.log("injection detect: after=\(after.map { "bundle=\($0.bundleIdentifier ?? "nil") role=\($0.role ?? "nil") editable=\($0.isEditable) hasFocus=\($0.hasFocusedElement) valueLength=\($0.value?.count ?? -1)" } ?? "nil")")

        guard let before, let after else {
            return .inserted
        }

        // No frontmost app → nothing to paste into (e.g. desktop)
        if before.bundleIdentifier == nil && after.bundleIdentifier == nil {
            return .copiedToClipboard
        }

        // AX completely blind (WeChat, Feishu, etc.): if we have a frontmost
        // app but can't see the focused element, assume Cmd+V worked.
        // Desktop/no-app cases are already handled above (bundleIdentifier == nil).
        if !before.hasFocusedElement || !after.hasFocusedElement {
            return .inserted
        }

        // Value changed → paste definitely worked (strongest signal)
        if let beforeValue = before.value, let afterValue = after.value, beforeValue != afterValue {
            return .inserted
        }

        // Either snapshot says editable → trust it
        if before.isEditable || after.isEditable {
            return .inserted
        }

        // Not editable and value didn't change → paste had nowhere to go
        return .copiedToClipboard
    }


}
