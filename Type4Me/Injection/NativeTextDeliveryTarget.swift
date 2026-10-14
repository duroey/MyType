import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Delivers to the original focused control without retaining its contents beyond a delivery.
final class NativeTextDeliveryTarget: TextDeliveryTarget {
    enum ControlAccess: Equatable {
        case blocked
        case opaque
        case verifiableText
    }

    enum FocusEvidence {
        case matched, unknown, changed, blocked

        /// Missing AX metadata does not prohibit normal paste into the same foreground app.
        var permitsSystemPaste: Bool { self == .matched || self == .unknown }

        /// Reading or writing a cached control requires positive evidence of its current focus.
        var permitsControlAccess: Bool { self == .matched }
    }

    private enum FocusLookup {
        case element(AXUIElement)
        case unavailable
        case otherApplication
    }

    private let application: NSRunningApplication
    private let text: String
    private let configuration: TextDeliveryConfiguration
    private var focusedElement: AXUIElement?
    private var beforeValue: String?
    private var beforeRange: NSRange?
    private var expectedValue: String?
    private var blocked = false

    /// Captures only the exact focused, non-secure text control and its insertion range.
    ///
    /// Args:
    ///   application: Application selected for this dictated output.
    ///   text: Text to insert once.
    ///   configuration: Limits on accessibility work and temporary text snapshots.
    init(application: NSRunningApplication, text: String, configuration: TextDeliveryConfiguration) {
        self.application = application
        self.text = text
        self.configuration = configuration
        guard sameApplicationIsFrontmost() else {
            blocked = true
            return
        }
        switch currentFocus() {
        case .otherApplication:
            blocked = true
        case .unavailable:
            break
        case .element(let element):
            focusedElement = element
            let access = controlAccess(of: element)
            guard access != .blocked else {
                blocked = true
                return
            }
            guard access == .verifiableText, let value = boundedValue(of: element),
                  let range = selectedRange(of: element),
                  range.location <= value.utf16.count,
                  range.length <= value.utf16.count - range.location,
                  text.utf16.count <= configuration.maximumValueUTF16Length,
                  value.utf16.count - range.length <= configuration.maximumValueUTF16Length - text.utf16.count
            else { return }
            beforeValue = value
            beforeRange = range
            expectedValue = (value as NSString).replacingCharacters(in: range, with: text)
        }
    }

    /// Returns whether the original application and, when available, control still own focus.
    func isCurrent() -> Bool {
        focusEvidence().permitsSystemPaste
    }

    /// Distinguishes absent focus metadata from evidence that the user selected another destination.
    private func focusEvidence() -> FocusEvidence {
        guard !blocked else { return .blocked }
        guard sameApplicationIsFrontmost() else { return .changed }
        switch currentFocus() {
        case .otherApplication:
            return .changed
        case .unavailable:
            return sameApplicationIsFrontmost() ? .unknown : .changed
        case .element(let current):
            guard controlAccess(of: current) != .blocked else { return .blocked }
            guard sameApplicationIsFrontmost() else { return .changed }
            guard let focusedElement else { return .unknown }
            return CFEqual(focusedElement, current) ? .matched : .changed
        }
    }

    /// Compares the exact resulting field value, never a substring or another input control.
    func observation() -> TextDeliveryObservation {
        let evidence = focusEvidence()
        guard evidence.permitsSystemPaste else { return .targetChanged }
        guard evidence.permitsControlAccess else { return .unavailable }
        guard let element = focusedElement, let beforeValue, let beforeRange, let expectedValue,
              let value = boundedValue(of: element)
        else { return .unavailable }
        let range = selectedRange(of: element)
        let afterRead = focusEvidence()
        guard afterRead.permitsSystemPaste else { return .targetChanged }
        guard afterRead.permitsControlAccess else { return .unavailable }
        return Self.compareReceipt(
            beforeValue: beforeValue, beforeRange: beforeRange, expectedValue: expectedValue,
            insertedUTF16Length: text.utf16.count, currentValue: value, currentRange: range
        )
    }

    /// Compares a receipt without considering equal pre-existing text proof of delivery.
    ///
    /// Args:
    ///   beforeValue: Original complete text value.
    ///   beforeRange: Original UTF-16 selection.
    ///   expectedValue: Expected complete value after replacing that selection.
    ///   insertedUTF16Length: Length of the inserted text in UTF-16 code units.
    ///   currentValue: Complete value read from the same focused control.
    ///   currentRange: Its current selection, if available.
    /// Returns:
    ///   Whether delivery is confirmed, unchanged, changed otherwise, or unverifiable.
    static func compareReceipt(
        beforeValue: String, beforeRange: NSRange, expectedValue: String,
        insertedUTF16Length: Int, currentValue: String, currentRange: NSRange?
    ) -> TextDeliveryObservation {
        if currentValue == expectedValue {
            if beforeValue != expectedValue { return .inserted }
            guard let range = currentRange, beforeRange.location >= 0, insertedUTF16Length >= 0 else { return .unavailable }
            let (caret, overflow) = beforeRange.location.addingReportingOverflow(insertedUTF16Length)
            guard !overflow else { return .unavailable }
            let expectedCaret = NSRange(location: caret, length: 0)
            if range == expectedCaret && range != beforeRange { return .inserted }
            return range == beforeRange ? .unchanged : .changed
        }
        guard currentValue == beforeValue else { return .changed }
        guard let range = currentRange else { return .unavailable }
        return range == beforeRange ? .unchanged : .changed
    }

    /// Invokes an enabled native Paste command without depending on its keyboard shortcut.
    ///
    /// Args:
    ///   shouldDispatch: Final clipboard ownership check immediately before the action.
    func pasteUsingMenu(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        guard isCurrent(), AXIsProcessTrusted() else { return .unavailable }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        setTimeout(on: appElement)
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.maximumMenuSearchSeconds
        guard let menuBar = elementAttribute(kAXMenuBarAttribute as CFString, from: appElement),
              let paste = findPaste(in: menuBar, deadline: deadline),
              isCurrent(), ProcessInfo.processInfo.systemUptime < deadline, shouldDispatch()
        else { return .unavailable }
        let result = AXUIElementPerformAction(paste, kAXPressAction as CFString)
        // A timeout or other ambiguous result may already have inserted text. Do not retry.
        return result == .actionUnsupported ? .unavailable : .dispatched
    }

    /// Replaces the original selection only when its field, value and range remain unchanged.
    ///
    /// Args:
    ///   shouldDispatch: Final clipboard ownership check immediately before the write.
    func insertDirectly(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        guard focusEvidence().permitsControlAccess, let element = focusedElement, let beforeValue, let beforeRange,
              boundedValue(of: element) == beforeValue,
              selectedRange(of: element) == beforeRange
        else { return .unavailable }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue, boundedValue(of: element) == beforeValue,
              selectedRange(of: element) == beforeRange, focusEvidence().permitsControlAccess, shouldDispatch()
        else { return .unavailable }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return result == .attributeUnsupported ? .unavailable : .dispatched
    }

    /// Posts one Command-V pair through the system event stream used by the original working injector.
    ///
    /// Args:
    ///   shouldDispatch: Final clipboard ownership check before posting either key event.
    func pasteUsingShortcut(shouldDispatch: () -> Bool) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              isCurrent()
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        TextInjectionEngine.markAsSyntheticInput(keyDown)
        TextInjectionEngine.markAsSyntheticInput(keyUp)
        guard sameApplicationIsFrontmost(), shouldDispatch() else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Checks the application on the main thread without moving accessibility work there.
    private func sameApplicationIsFrontmost() -> Bool {
        let readPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let pid = Thread.isMainThread ? readPID() : DispatchQueue.main.sync(execute: readPID)
        return !application.isTerminated && pid == application.processIdentifier
    }

    /// Queries focus directly; window-tree traversal must never guess the destination control.
    private func currentFocus() -> FocusLookup {
        guard AXIsProcessTrusted() else { return .unavailable }
        let system = AXUIElementCreateSystemWide()
        setTimeout(on: system)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        setTimeout(on: app)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute as CFString, from: system)
            ?? elementAttribute(kAXFocusedUIElementAttribute as CFString, from: app)
        else { return .unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return .unavailable }
        return pid == application.processIdentifier ? .element(element) : .otherApplication
    }

    /// Classifies metadata before reading values, leaving opaque editors eligible for native paste.
    private func controlAccess(of element: AXUIElement) -> ControlAccess {
        let role = attribute(kAXRoleAttribute as CFString, from: element) as? String
        var subroleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        return Self.controlAccess(
            role: role, subrole: subroleValue as? String,
            isEnabled: attribute(kAXEnabledAttribute as CFString, from: element) as? Bool,
            isEditable: attribute("AXEditable" as CFString, from: element) as? Bool,
            metadataReadable: role != nil && (
                (result == .success && subroleValue is String) || result == .attributeUnsupported || result == .noValue
            )
        )
    }

    /// Separates explicitly forbidden controls from opaque editors without reading their text.
    ///
    /// Args:
    ///   role: Accessibility role, if exposed.
    ///   subrole: Accessibility subrole, checked for secure fields before allowing value reads.
    ///   isEnabled: Explicit enabled state; missing metadata does not establish a prohibition.
    ///   isEditable: Explicit editable state; false prohibits automatic delivery.
    ///   metadataReadable: Whether role and security metadata could be read reliably.
    /// Returns:
    ///   Blocked, opaque native-paste-only, or eligible for temporary text verification.
    static func controlAccess(
        role: String?, subrole: String?, isEnabled: Bool?, isEditable: Bool?, metadataReadable: Bool = true
    ) -> ControlAccess {
        guard ![role, subrole].compactMap({ $0 }).contains(where: {
            $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password")
        }), isEnabled != false, isEditable != false else { return .blocked }
        guard metadataReadable, let role,
              [kAXTextFieldRole as String, kAXTextAreaRole as String,
               kAXComboBoxRole as String, "AXSearchField"].contains(role)
        else { return .opaque }
        return .verifiableText
    }

    /// Reads a short-lived value only after the control passes the secure-field check.
    private func boundedValue(of element: AXUIElement) -> String? {
        guard controlAccess(of: element) == .verifiableText,
              let value = attribute(kAXValueAttribute as CFString, from: element) as? String,
              value.utf16.count <= configuration.maximumValueUTF16Length
        else { return nil }
        return value
    }

    /// Reads and validates the accessibility selection's UTF-16 range.
    private func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute as CFString, from: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Searches only existing menu nodes within the configured count, depth and time limits.
    private func findPaste(in menuBar: AXUIElement, deadline: TimeInterval) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(menuBar, 0)]
        var index = 0
        while index < queue.count, index < configuration.maximumMenuNodes,
              ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[index]
            index += 1
            setTimeout(on: element)
            if isPasteMenuItem(element), ProcessInfo.processInfo.systemUptime < deadline { return element }
            guard depth < configuration.maximumMenuDepth,
                  ProcessInfo.processInfo.systemUptime < deadline else { continue }
            let remaining = configuration.maximumMenuNodes - queue.count
            guard remaining > 0 else { continue }
            var children: CFArray?
            if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, remaining, &children) == .success,
               let elements = children as? [AXUIElement] {
                queue.append(contentsOf: elements.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    /// Matches only enabled standard Paste, excluding variants such as Paste and Match Style.
    private func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        let role = attribute(kAXRoleAttribute as CFString, from: element) as? String
        guard role == kAXMenuItemRole as String,
              let enabled = attribute(kAXEnabledAttribute as CFString, from: element) as? Bool, enabled
        else { return false }
        return Self.isStandardPasteMenuItem(
            role: role, isEnabled: enabled,
            title: attribute(kAXTitleAttribute as CFString, from: element) as? String
        )
    }

    /// Recognizes a Paste command by its exact standard title, never by a remappable shortcut.
    ///
    /// Args:
    ///   role: Accessibility role of the candidate menu node.
    ///   isEnabled: Whether the command is currently enabled.
    ///   title: Exact native menu title in a supported application language.
    /// Returns:
    ///   True only for an enabled standard Paste command, including one without a shortcut.
    static func isStandardPasteMenuItem(role: String?, isEnabled: Bool?, title: String?) -> Bool {
        guard role == kAXMenuItemRole as String, isEnabled == true, let title else { return false }
        return ["Paste", "粘贴", "貼上"].contains(title)
    }

    /// Copies one accessibility attribute without logging its value.
    private func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    /// Checks an attribute's type before treating it as an accessibility element.
    private func elementAttribute(_ name: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, from: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = unsafeDowncast(value, to: AXUIElement.self)
        setTimeout(on: result)
        return result
    }

    /// Bounds each cross-process accessibility request independently.
    private func setTimeout(on element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, Float(configuration.accessibilityTimeoutSeconds))
    }
}
