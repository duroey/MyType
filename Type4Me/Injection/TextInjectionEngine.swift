import Cocoa
import Foundation

final class TextInjectionEngine: @unchecked Sendable {

    /// Per-process randomized marker tagged onto synthetic events (e.g. Cmd+V)
    /// so HotkeyManager recognizes them as internal and avoids re-triggering hotkeys.
    private static let syntheticInputEventMarker = Int64.random(in: 1...Int64.max)

    static func markAsSyntheticInput(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: syntheticInputEventMarker
        )
    }

    static func isSyntheticInput(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticInputEventMarker
    }

    enum ClipboardRetention: Sendable, Equatable {
        /// Keep the dictated result in the system clipboard after the paste attempt.
        case retainResult
        /// Preserve every clipboard format by using text events without accessing it.
        case restoreOriginal
    }
    typealias ClipboardSnapshot = Type4Me.ClipboardSnapshot

    enum DeliveryTarget: Equatable {
        case app(NSRunningApplication)
        case fallbackToClipboard
    }

    static func resolveDeliveryTarget(
        frontmost: NSRunningApplication?,
        selfBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> DeliveryTarget {
        guard let frontmost,
              frontmost.bundleIdentifier != selfBundleIdentifier,
              !frontmost.isTerminated
        else {
            return .fallbackToClipboard
        }
        return .app(frontmost)
    }

    /// The editable text view inside Type4Me's own key window that should receive
    /// dictated text, or `nil` when Type4Me is not active or nothing editable has
    /// keyboard focus. Covers SwiftUI `TextEditor` and the field editor of a
    /// `TextField` that is currently being edited.
    @MainActor
    static func ownEditableTextView(
        isAppActive: Bool,
        firstResponder: NSResponder?
    ) -> NSTextView? {
        guard isAppActive,
              let textView = firstResponder as? NSTextView,
              textView.isEditable
        else { return nil }
        return textView
    }

    /// Inserts `text` at the selection of Type4Me's own focused text view.
    /// Returns `false` without side effects when no such view exists.
    static func insertIntoOwnFocusedTextView(_ text: String) -> Bool {
        let insert: @MainActor () -> Bool = {
            guard let textView = ownEditableTextView(
                isAppActive: NSApp.isActive,
                firstResponder: NSApp.keyWindow?.firstResponder
            ) else { return false }
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated(insert)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(insert) }
    }


    struct FocusedElementSnapshot {
        var element: AXUIElement? = nil
        var processIdentifier: pid_t? = nil
        var bundleIdentifier: String? = nil
        var role: String? = nil
        var subrole: String? = nil
        var value: String? = nil
        var placeholder: String? = nil
        var accessibilityDescription: String? = nil
        var selectedRange: NSRange? = nil
        var isEditable: Bool = false
        var hasFocusedElement: Bool = false
    }

    /// Whether this engine should retain the dictated result or restore the
    /// clipboard that existed before injection.
    var clipboardRetention: ClipboardRetention = .restoreOriginal
    /// Injects text once and returns a verified or explicitly unconfirmed outcome.
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        return deliverText(text, trackingMetadata: nil).outcome
    }

    /// Inject text while capturing enough Accessibility context to observe a
    /// later correction in the exact field Type4Me wrote into.
    func injectTracked(
        _ text: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID,
        shouldCaptureApp: @Sendable (String?) -> Bool
    ) -> TrackedInjectionResult {
        guard !text.isEmpty else {
            return TrackedInjectionResult(outcome: .inserted, observationContext: nil)
        }
        return deliverText(
            text,
            trackingMetadata: (
                sourceText: sourceText,
                sourceRecordID: sourceRecordID,
                modeID: modeID
            ),
            authorizeCapture: shouldCaptureApp
        )
    }

    /// Copies text atomically with its marker and verifies the pasteboard write.
    @discardableResult
    func copyToClipboard(_ text: String, transient: Bool = false) -> Bool {
        let succeeded = SystemTextDeliveryClipboard().write(text, transient: transient) != nil
        if !succeeded { DebugFileLogger.log("injection: clipboard write could not be verified") }
        return succeeded
    }

    /// Delivers to the original input, with optional authorized correction-learning snapshots.
    private func deliverText(
        _ text: String,
        trackingMetadata: (sourceText: String, sourceRecordID: String, modeID: UUID)?,
        authorizeCapture: (String?) -> Bool = { _ in false }
    ) -> TrackedInjectionResult {
        let shouldRestoreClipboard = Self.shouldRestoreClipboard(retention: clipboardRetention)
        let frontmost = FocusedInputResolver.currentApplication()
        let deliveryTarget = Self.resolveDeliveryTarget(frontmost: frontmost)
        guard case .app(let application) = deliveryTarget else {
            // Type4Me itself is frontmost (e.g. Settings → About → Report an Issue).
            // Insert in-process into our own focused text view instead of posting
            // Cmd+V, so we never paste into another app and never touch the clipboard.
            if Self.mayInsertIntoOwnApp(targetPID: frontmost?.processIdentifier,
                                       ownPID: ProcessInfo.processInfo.processIdentifier),
               Self.insertIntoOwnFocusedTextView(text) {
                if !shouldRestoreClipboard {
                    copyToClipboard(text, transient: false)
                }
                DebugFileLogger.log("injection: inserted into Type4Me's own focused text view")
                return TrackedInjectionResult(outcome: .inserted, observationContext: nil)
            }
            DebugFileLogger.log("injection: no valid input target; text remains in MyType history")
            return TrackedInjectionResult(
                outcome: .notInserted,
                observationContext: nil
            )
        }

        let configuration: TextDeliveryConfiguration
        do { configuration = try .bundled() }
        catch {
            DebugFileLogger.log("injection: invalid delivery configuration; automatic delivery skipped")
            return TrackedInjectionResult(
                outcome: .notInserted, observationContext: nil
            )
        }
        let before = trackingMetadata != nil
            ? captureFocusedElementSnapshot(isPrePaste: true, authorize: authorizeCapture)
            : nil

        let target = NativeTextDeliveryTarget(application: application, text: text, configuration: configuration)
        let result = shouldRestoreClipboard
            ? ClipboardFreeDeliveryTransaction(configuration: configuration).deliver(to: target)
            : ClipboardDeliveryTransaction(configuration: configuration).deliver(text, to: target, restoreOriginal: false)
        let outcome = Self.deliveryOutcome(result)
        DebugFileLogger.log("injection: delivery result=\(result)")

        let after = trackingMetadata != nil && outcome == .inserted
            ? captureFocusedElementSnapshot(isPrePaste: false, authorize: authorizeCapture)
            : nil

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

    static func shouldRestoreClipboard(retention: ClipboardRetention) -> Bool {
        retention == .restoreOriginal
    }

    /// Allows in-process editing only after focus resolution positively names this process.
    ///
    /// Args:
    ///   targetPID: Resolved keyboard owner; nil includes ambiguous floating panels.
    ///   ownPID: This application's process identifier.
    /// Returns:
    ///   Whether the app's own first responder can be used as the destination.
    static func mayInsertIntoOwnApp(targetPID: pid_t?, ownPID: pid_t) -> Bool {
        targetPID == ownPID
    }


    /// Maps delivery evidence to the existing bilingual feedback without claiming a sent event succeeded.
    static func deliveryOutcome(_ result: TextDeliveryResult) -> InjectionOutcome {
        switch result {
        case .inserted: return .inserted
        case .pasteAttempted: return .pasteAttemptedClipboardRetained
        case .clipboardOnly: return .copiedToClipboard
        case .clipboardChanged:
            return .actionFailed(L("剪贴板已变化，文本可从历史记录恢复", "Clipboard changed; recover the text from history"))
        case .clipboardWriteFailed:
            return .actionFailed(L("无法写入剪贴板，文本可从历史记录恢复", "Could not write to clipboard; recover the text from history"))
        case .inputAttempted: return .inputAttempted
        case .notDelivered: return .notInserted
        }
    }

    private func enableEnhancedAX(for app: NSRunningApplication) {
        guard AXIsProcessTrusted(), !app.isTerminated else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    private func captureFocusedElementSnapshot(
        isPrePaste: Bool,
        authorize: (String?) -> Bool
    ) -> FocusedElementSnapshot? {
        let frontmostApp = FocusedInputResolver.currentApplication()
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        return Self.authorizedSnapshot(
            bundleIdentifier: frontmostBundleID,
            authorize: authorize
        ) {
            focusedElementSnapshot(
                frontmostApp: frontmostApp,
                frontmostBundleID: frontmostBundleID,
                isPrePaste: isPrePaste,
                authorize: authorize
            )
        }
    }

    private func focusedElementSnapshot(
        frontmostApp: NSRunningApplication?,
        frontmostBundleID: String?,
        isPrePaste: Bool,
        authorize: (String?) -> Bool
    ) -> FocusedElementSnapshot? {
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
        AXUIElementSetMessagingTimeout(systemWide, isPrePaste ? 0.05 : 0.25)
        var focusedValue: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        // Pre-paste snapshot is on the critical path: keep it strictly bounded and fast.
        // If system-wide query fails initially, allow a fast enhanced-AX retry without sleeping,
        // but never perform 30ms sleep or window tree traversal before Cmd+V is dispatched.
        if isPrePaste {
            if status == .success, let focusedValue {
                let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
                return snapshotFromElement(element, authorize: authorize, timeout: 0.05)
            }
            if let frontmostApp {
                enableEnhancedAX(for: frontmostApp)
                status = AXUIElementCopyAttributeValue(
                    systemWide,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedValue
                )
                if status == .success, let focusedValue {
                    let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
                    return snapshotFromElement(element, authorize: authorize, timeout: 0.05)
                }
            }
            return nil
        }

        // Post-paste snapshot is off the critical path: allow enhanced AX retry and tree traversal.
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
                return snapshotFromElement(found, authorize: authorize, timeout: 0.25)
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
        return snapshotFromElement(element, authorize: authorize, timeout: 0.25)
    }

    private func snapshotFromElement(
        _ element: AXUIElement,
        authorize: (String?) -> Bool,
        timeout: Float = 0.05
    ) -> FocusedElementSnapshot? {
        AXUIElementSetMessagingTimeout(element, timeout)

        var processIdentifier: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &processIdentifier)
        let actualBundleID = Self.resolveElementBundleIdentifier(
            pidStatus: pidStatus,
            pid: processIdentifier
        )
        return Self.authorizedSnapshot(
            bundleIdentifier: actualBundleID,
            authorize: authorize
        ) {
            let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
            let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
            let value = Self.trackedValue(role: role, subrole: subrole) {
                copyStringAttribute(kAXValueAttribute as CFString, from: element)
            }
            let placeholder = copyStringAttribute(kAXPlaceholderValueAttribute as CFString, from: element)
            let accessibilityDescription = copyStringAttribute(kAXDescriptionAttribute as CFString, from: element)
            let selectedRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
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
                bundleIdentifier: actualBundleID,
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
    }

    /// Traverse the app's focused window tree to find the first editable element.
    /// Used as fallback when system-wide kAXFocusedUIElementAttribute fails.
    private func findEditableElementInApp(_ app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)

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
              !Self.isSecureTextRole(role: after.role, subrole: after.subrole),
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

    /// Resolve the bundle identifier of the application owning the AX element.
    /// Fails closed (returns `nil`) if the PID cannot be retrieved or the owning
    /// application bundle identifier cannot be resolved, avoiding fail-open
    /// access to an element from an unknown or excluded process.
    static func resolveElementBundleIdentifier(
        pidStatus: AXError,
        pid: pid_t,
        appLookup: (pid_t) -> String? = { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
    ) -> String? {
        guard pidStatus == .success else { return nil }
        return appLookup(pid)
    }

    /// Gate every focused-element read on the app that actually holds focus
    /// right now. Fails closed (returns `nil` without invoking `read`) when
    /// the app identity is unknown or empty, or when no tracking consumer is
    /// allowed to observe that app's text.
    static func authorizedSnapshot(
        bundleIdentifier: String?,
        authorize: (String?) -> Bool,
        read: () -> FocusedElementSnapshot?
    ) -> FocusedElementSnapshot? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty, authorize(bundleIdentifier) else { return nil }
        return read()
    }

    static func trackedValue(
        role: String?,
        subrole: String?,
        read: () -> String?
    ) -> String? {
        guard !isSecureTextRole(role: role, subrole: subrole) else { return nil }
        return read()
    }

    private static func isSecureTextRole(role: String?, subrole: String?) -> Bool {
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
}
