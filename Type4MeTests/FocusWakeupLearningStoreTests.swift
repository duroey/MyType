import XCTest
@testable import Type4Me

final class FocusWakeupLearningStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FocusWakeupLearningStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testResetForNoiseCalibrationClearsWakeupLearningProfiles() {
        SpeechRMSProfileStore.record(4_000, defaults: defaults, source: "test")
        FalseStartRMSProfileStore.record(2_000, defaults: defaults, source: "test")

        FocusWakeupLearningStore.resetForNoiseCalibration(defaults: defaults)

        XCTAssertNil(SpeechRMSProfileStore.snapshot(defaults: defaults))
        XCTAssertNil(FalseStartRMSProfileStore.snapshot(defaults: defaults))
    }
}
