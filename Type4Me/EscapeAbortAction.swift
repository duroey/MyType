enum EscapeAbortAction: Equatable {
    case passThrough
    case pauseFocusWakeupWaiting
    case cancelActiveSession

    /// Returns how Escape should be handled for the current floating bar phase.
    ///
    /// Args:
    ///   phase: Current floating bar phase.
    ///
    /// Returns:
    ///   Escape handling action for the phase.
    static func action(for phase: FloatingBarPhase) -> EscapeAbortAction {
        switch phase {
        case .focusWaiting:
            return .pauseFocusWakeupWaiting
        case .recording, .processing, .preparing:
            return .cancelActiveSession
        case .hidden, .done, .error:
            return .passThrough
        }
    }
}

enum RMSGatePolicy {
    /// Returns whether a pipeline start should use RMS-based auto stop.
    ///
    /// Args:
    ///   focusWakeupEnabled: Whether the automatic wakeup workflow is enabled.
    ///
    /// Returns:
    ///   True when the end RMS gate should stop and submit the pipeline.
    static func usesEndGateForPipelineStart(focusWakeupEnabled: Bool) -> Bool {
        focusWakeupEnabled
    }
}
