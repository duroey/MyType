import Foundation
import XCTest
@testable import Type4Me

final class FocusWakeupRetentionPolicyTests: XCTestCase {
    private let config = FocusWakeupRetentionPolicy<String>.Config(
        maxUnknownPolls: 2,
        maxUnknownDuration: 1.0
    )

    func testSameAppUnknownKeepsFocusWithinGrace() {
        let start = Date(timeIntervalSince1970: 100)
        var policy = FocusWakeupRetentionPolicy<String>(config: config)

        XCTAssertEqual(policy.update(.editable("wechat-input", pid: 42), at: start), .arm("wechat-input"))
        XCTAssertEqual(
            policy.update(.unknown(pid: 42), at: start.addingTimeInterval(0.2)),
            .keep("wechat-input")
        )
    }

    func testUnknownClearsFocusAfterGracePolls() {
        let start = Date(timeIntervalSince1970: 100)
        var policy = FocusWakeupRetentionPolicy<String>(config: config)

        _ = policy.update(.editable("wechat-input", pid: 42), at: start)
        _ = policy.update(.unknown(pid: 42), at: start.addingTimeInterval(0.1))
        _ = policy.update(.unknown(pid: 42), at: start.addingTimeInterval(0.2))

        XCTAssertEqual(policy.update(.unknown(pid: 42), at: start.addingTimeInterval(0.3)), .clear)
        XCTAssertNil(policy.currentFocus)
    }

    func testUnknownClearsFocusAfterGraceDuration() {
        let start = Date(timeIntervalSince1970: 100)
        var policy = FocusWakeupRetentionPolicy<String>(config: config)

        _ = policy.update(.editable("wechat-input", pid: 42), at: start)
        _ = policy.update(.unknown(pid: 42), at: start.addingTimeInterval(0.1))

        XCTAssertEqual(policy.update(.unknown(pid: 42), at: start.addingTimeInterval(1.2)), .clear)
    }

    func testDifferentAppUnknownClearsImmediately() {
        let start = Date(timeIntervalSince1970: 100)
        var policy = FocusWakeupRetentionPolicy<String>(config: config)

        _ = policy.update(.editable("wechat-input", pid: 42), at: start)

        XCTAssertEqual(policy.update(.unknown(pid: 99), at: start.addingTimeInterval(0.1)), .clear)
    }

    func testConfirmedNoEditableFocusClearsImmediately() {
        let start = Date(timeIntervalSince1970: 100)
        var policy = FocusWakeupRetentionPolicy<String>(config: config)

        _ = policy.update(.editable("wechat-input", pid: 42), at: start)

        XCTAssertEqual(policy.update(.confirmedNoEditableFocus, at: start.addingTimeInterval(0.1)), .clear)
    }

    func testWindowFallbackOnlyRunsWhenFocusedElementIsUnavailable() {
        XCTAssertFalse(FocusWakeupController.shouldUseEditableWindowFallback(focusedElementWasUnavailable: false))
        XCTAssertTrue(FocusWakeupController.shouldUseEditableWindowFallback(focusedElementWasUnavailable: true))
    }
}
