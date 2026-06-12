import XCTest
@testable import Type4Me

final class FalseStartRMSProfileStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FalseStartRMSProfileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordStoresBoundedFalseStartSamples() {
        FalseStartRMSProfileStore.record(1_000, defaults: defaults, maxSamples: 3, source: "test")
        FalseStartRMSProfileStore.record(2_000, defaults: defaults, maxSamples: 3, source: "test")
        FalseStartRMSProfileStore.record(3_000, defaults: defaults, maxSamples: 3, source: "test")
        FalseStartRMSProfileStore.record(4_000, defaults: defaults, maxSamples: 3, source: "test")

        let snapshot = FalseStartRMSProfileStore.snapshot(defaults: defaults)

        XCTAssertEqual(snapshot?.samples, 3)
        XCTAssertEqual(snapshot?.highFalseStartRMS, 4_000)
    }

    func testInvalidFalseStartSamplesAreIgnored() {
        FalseStartRMSProfileStore.record(.nan, defaults: defaults, maxSamples: 3, source: "test")
        FalseStartRMSProfileStore.record(0, defaults: defaults, maxSamples: 3, source: "test")

        XCTAssertNil(FalseStartRMSProfileStore.snapshot(defaults: defaults))
    }
}
