import XCTest
@testable import Type4Me

final class EscapeAbortActionTests: XCTestCase {
    func testFocusWaitingEscapePausesFocusWakeup() {
        XCTAssertEqual(
            EscapeAbortAction.action(for: .focusWaiting),
            .pauseFocusWakeupWaiting
        )
    }

    func testRecordingEscapeCancelsActiveSession() {
        XCTAssertEqual(
            EscapeAbortAction.action(for: .recording),
            .cancelActiveSession
        )
    }

    func testHiddenEscapePassesThrough() {
        XCTAssertEqual(
            EscapeAbortAction.action(for: .hidden),
            .passThrough
        )
    }

    func testEnabledFocusWakeupUsesEndRMSForHotkeyPipelineStart() {
        XCTAssertTrue(RMSGatePolicy.usesEndGateForPipelineStart(focusWakeupEnabled: true))
    }

    func testDisabledFocusWakeupKeepsManualHotkeyPipelineWithoutEndRMS() {
        XCTAssertFalse(RMSGatePolicy.usesEndGateForPipelineStart(focusWakeupEnabled: false))
    }
}
