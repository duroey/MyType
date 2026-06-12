import Foundation

enum FocusWakeupLearningStore {
    /// Clears wakeup learning that depends on the current room and microphone position.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    static func resetForNoiseCalibration(defaults: UserDefaults = .standard) {
        FalseStartRMSProfileStore.reset(defaults: defaults)
        SpeechRMSProfileStore.reset(defaults: defaults)
        DebugFileLogger.log("noise floor calibration reset wakeup RMS learning profiles")
    }
}
