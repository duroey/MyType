import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Sends the hardware shortcut only to one verified, non-secure input control.
@MainActor
final class BoyaButtonActionSender {
    /// Immutable AX references cross queues for serial preflight and the final main-actor check.
    private struct ValidationRequest: @unchecked Sendable {
        let snapshot: FocusedInputResolver.Snapshot?
    }

    /// Contains focus identity and timing metadata only, never the input control's contents.
    private struct ValidatedTarget: @unchecked Sendable {
        let snapshot: FocusedInputResolver.Snapshot
        let validatedAt: Double
        let foregroundPID: pid_t?
    }

    private let configuration: BoyaButtonConfiguration
    private let focusConfiguration: TextDeliveryConfiguration
    private let validationQueue = DispatchQueue(label: "com.type4me.boya-input-validation", qos: .userInitiated)
    private var pendingAction: Task<Void, Never>?
    private var textPosted = false
    private var generation = UUID()

    /// Loads the existing bounded focus policy without accessing another application's text.
    ///
    /// Args:
    ///   configuration: Validated hardware action and timing settings.
    /// Throws:
    ///   An error when the bundled focus configuration is invalid.
    init(configuration: BoyaButtonConfiguration) throws {
        self.configuration = configuration
        var focus = try TextDeliveryConfiguration.bundled()
        focus.accessibilityTimeoutSeconds = min(focus.accessibilityTimeoutSeconds, configuration.axTimeoutSeconds)
        focusConfiguration = focus
    }

    /// Invalidates queued validation and delayed Return before a disconnect or newer action.
    ///
    /// Returns:
    ///   Whether text had been posted with a Return still pending.
    @discardableResult
    func cancel() -> Bool {
        let hadPendingReturn = pendingAction != nil && textPosted
        generation = UUID()
        pendingAction?.cancel()
        pendingAction = nil
        textPosted = false
        return hadPendingReturn
    }

    /// Defers extended focus checks so the HID callback can immediately process subsequent reports.
    ///
    /// Args:
    ///   isCurrent: Revalidates the service's connection and action token without queuing work.
    ///   completion: Receives a delivery-attempt outcome, never a claim of target receipt.
    func send(
        isCurrent: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (BoyaButtonFeedback) -> Void
    ) {
        cancel()
        let actionGeneration = generation
        let actionStartedAt = ProcessInfo.processInfo.systemUptime
        let foregroundAtTrigger = NSWorkspace.shared.frontmostApplication?.processIdentifier
        pendingAction = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == actionGeneration {
                    self.pendingAction = nil
                    self.textPosted = false
                }
            }
            guard isCurrent(), self.permitsInput(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundAtTrigger,
                  ProcessInfo.processInfo.systemUptime - actionStartedAt <= self.focusConfiguration.maximumFocusResolutionSeconds
            else { completion(.chooseInput); return }
            let target = await self.validate(nil)
            guard self.generation == actionGeneration, !Task.isCancelled else { return }
            guard let target, target.foregroundPID == foregroundAtTrigger,
                  target.validatedAt - actionStartedAt <= self.focusConfiguration.maximumFocusResolutionSeconds else {
                completion(.chooseInput)
                return
            }
            guard let textEvents = self.events(keyCode: 0, text: self.configuration.text),
                  let returnEvents = self.events(keyCode: self.configuration.returnKeyCode) else {
                completion(.failed)
                return
            }
            guard self.canPost(target, isCurrent: isCurrent) else { completion(.chooseInput); return }
            let pid = target.snapshot.application.processIdentifier
            for event in textEvents { event.postToPid(pid) }
            self.textPosted = true
            do { try await Task.sleep(for: .seconds(self.configuration.returnDelaySeconds)) }
            catch { return }
            guard self.generation == actionGeneration, !Task.isCancelled else { return }
            guard isCurrent(), self.permitsInput() else { completion(.returnCancelled); return }
            let current = await self.validate(target.snapshot)
            guard self.generation == actionGeneration, !Task.isCancelled else { return }
            guard let current, self.canPost(current, isCurrent: isCurrent) else {
                completion(.returnCancelled)
                return
            }
            for event in returnEvents { event.postToPid(pid) }
            completion(.posted)
        }
    }

    /// Rechecks exact focus immediately before posting, with one short shared AX deadline.
    ///
    /// Args:
    ///   target: Bounded worker result for the exact destination control.
    ///   isCurrent: Connection and action-token gate owned by the service.
    /// Returns:
    ///   True only while the same non-secure control and device session still permit input.
    private func canPost(_ target: ValidatedTarget, isCurrent: () -> Bool) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - target.validatedAt
        guard age >= 0, age <= configuration.axTimeoutSeconds,
              isCurrent(), permitsInput(), !target.snapshot.application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.foregroundPID,
              let element = target.snapshot.element else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.axTimeoutSeconds
        guard Self.isEditable(element, configuration: focusConfiguration, deadline: deadline),
              let remaining = Self.bounded(focusConfiguration, deadline: deadline),
              FocusedInputResolver.isCurrent(target.snapshot, configuration: remaining),
              ProcessInfo.processInfo.systemUptime < deadline else { return false }
        return isCurrent() && permitsInput()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.foregroundPID
    }

    /// Checks posting, accessibility, and secure-input gates immediately before output.
    ///
    /// Returns:
    ///   True only while the process can inspect focus and post keyboard events.
    private func permitsInput() -> Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled()
    }

    /// Moves initial discovery and extended accessibility validation off the main run loop.
    ///
    /// Args:
    ///   original: Original target for Return, or nil to capture a new Go destination.
    /// Returns:
    ///   A fresh focus proof, or nil after the shared validation budget expires.
    private func validate(_ original: FocusedInputResolver.Snapshot?) async -> ValidatedTarget? {
        let request = ValidationRequest(snapshot: original)
        let configuration = focusConfiguration
        return await withCheckedContinuation { continuation in
            validationQueue.async {
                continuation.resume(returning: Self.validatedTarget(request, configuration: configuration))
            }
        }
    }

    /// Resolves or revalidates one input within the existing global focus-work budget.
    ///
    /// Args:
    ///   request: Optional original focus identity to retain across Go and Return.
    ///   configuration: Existing focus limits, including the total validation deadline.
    /// Returns:
    ///   A non-secure editable target, or nil without reading its text.
    nonisolated private static func validatedTarget(
        _ request: ValidationRequest, configuration: TextDeliveryConfiguration
    ) -> ValidatedTarget? {
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.maximumFocusResolutionSeconds
        let foreground = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let bounds = bounded(configuration, deadline: deadline),
              let snapshot = request.snapshot ?? FocusedInputResolver.resolve(configuration: bounds),
              snapshot.application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = snapshot.element,
              isEditable(element, configuration: configuration, deadline: deadline),
              let remaining = bounded(configuration, deadline: deadline),
              FocusedInputResolver.isCurrent(snapshot, configuration: remaining),
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        let validatedAt = ProcessInfo.processInfo.systemUptime
        let currentForeground = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard currentForeground == foreground, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return ValidatedTarget(snapshot: snapshot, validatedAt: validatedAt,
                               foregroundPID: currentForeground)
    }

    /// Gives each phase only the unused portion of one fixed validation deadline.
    ///
    /// Args:
    ///   configuration: Shared input-delivery limits.
    ///   deadline: Monotonic deadline for this worker operation.
    /// Returns:
    ///   Reduced bounds, or nil once the operation has exhausted its budget.
    nonisolated private static func bounded(
        _ configuration: TextDeliveryConfiguration, deadline: Double
    ) -> TextDeliveryConfiguration? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        var value = configuration
        value.maximumFocusResolutionSeconds = remaining
        value.accessibilityTimeoutSeconds = min(value.accessibilityTimeoutSeconds, remaining)
        return value
    }

    /// Classifies metadata using the shared policy without requesting text or selection.
    ///
    /// Args:
    ///   element: Exact focused accessibility control.
    ///   configuration: Per-call accessibility bounds.
    ///   deadline: Shared monotonic deadline for all validation work.
    /// Returns:
    ///   True only for a reliably classified, non-secure editable text control.
    nonisolated private static func isEditable(
        _ element: AXUIElement, configuration: TextDeliveryConfiguration, deadline: Double
    ) -> Bool {
        let role = attribute(kAXRoleAttribute as CFString, from: element, configuration: configuration, deadline: deadline)
        let subrole = attribute(kAXSubroleAttribute as CFString, from: element, configuration: configuration, deadline: deadline)
        let enabled = attribute(kAXEnabledAttribute as CFString, from: element, configuration: configuration, deadline: deadline)
        let editable = attribute("AXEditable" as CFString, from: element, configuration: configuration, deadline: deadline)
        return NativeTextDeliveryTarget.controlAccess(
            role: role.value as? String, subrole: subrole.value as? String,
            isEnabled: enabled.value as? Bool, isEditable: editable.value as? Bool,
            metadataReadable: role.status == .success && role.value is String
                && ((subrole.status == .success && subrole.value is String)
                    || subrole.status == .attributeUnsupported || subrole.status == .noValue)
                && metadataAvailable(enabled.status) && metadataAvailable(editable.status)
        ) == .verifiableText && ProcessInfo.processInfo.systemUptime < deadline
    }

    /// Distinguishes an absent optional attribute from a failed accessibility connection.
    ///
    /// Args:
    ///   status: Result of a bounded metadata read.
    /// Returns:
    ///   Whether the result can be safely classified by the shared control-access policy.
    nonisolated private static func metadataAvailable(_ status: AXError) -> Bool {
        status == .success || status == .attributeUnsupported || status == .noValue
    }

    /// Reads one metadata attribute while retaining the operation's common deadline.
    ///
    /// Args:
    ///   name: Role, subrole, enabled, or editable key; never a text-value key.
    ///   element: Focused input control.
    ///   configuration: Maximum duration of an individual accessibility call.
    ///   deadline: Shared monotonic deadline for the validation operation.
    /// Returns:
    ///   The accessibility status and optional metadata value.
    nonisolated private static func attribute(
        _ name: CFString, from element: AXUIElement,
        configuration: TextDeliveryConfiguration, deadline: Double
    ) -> (status: AXError, value: CFTypeRef?) {
        guard let bounds = bounded(configuration, deadline: deadline) else { return (.cannotComplete, nil) }
        AXUIElementSetMessagingTimeout(element, Float(bounds.accessibilityTimeoutSeconds))
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        return (status, value)
    }

    /// Creates a complete down/up pair tagged to bypass Type4Me's own hotkey handling.
    ///
    /// Args:
    ///   keyCode: Virtual key code; zero carries explicit Unicode text.
    ///   text: Literal shortcut text, or nil for Return.
    /// Returns:
    ///   Two prepared events, or nil before any partial action is posted.
    private func events(keyCode: UInt16, text: String? = nil) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = []
            TextInjectionEngine.markAsSyntheticInput(event)
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                }
            }
        }
        return [down, up]
    }
}
