import XCTest
@testable import Type4Me

final class SpeechRMSProfileStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SpeechRMSProfileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordStoresBoundedSpeechProfileSamples() {
        SpeechRMSProfileStore.record(400, defaults: defaults, maxSamples: 3, source: "test")
        SpeechRMSProfileStore.record(800, defaults: defaults, maxSamples: 3, source: "test")
        SpeechRMSProfileStore.record(1_200, defaults: defaults, maxSamples: 3, source: "test")
        SpeechRMSProfileStore.record(1_600, defaults: defaults, maxSamples: 3, source: "test")

        let snapshot = SpeechRMSProfileStore.snapshot(defaults: defaults)

        XCTAssertEqual(snapshot?.samples, 3)
        XCTAssertEqual(snapshot?.lowSpeechRMS, 800)
        XCTAssertEqual(snapshot?.medianSpeechRMS, 1_200)
    }

    func testInvalidSpeechProfileSamplesAreIgnored() {
        SpeechRMSProfileStore.record(.nan, defaults: defaults, maxSamples: 3, source: "test")
        SpeechRMSProfileStore.record(0, defaults: defaults, maxSamples: 3, source: "test")

        XCTAssertNil(SpeechRMSProfileStore.snapshot(defaults: defaults))
    }
}
