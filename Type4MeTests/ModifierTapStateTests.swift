import XCTest
@testable import Type4Me

final class ModifierTapStateTests: XCTestCase {
    func testModifierTapFiresWhenReleasedWithoutComboKey() {
        var state = ModifierTapState()

        state.pressTarget()

        XCTAssertTrue(state.releaseTarget())
    }

    func testModifierTapDoesNotFireAfterComboKey() {
        var state = ModifierTapState()

        state.pressTarget()
        state.markNonModifierKeyDown()

        XCTAssertFalse(state.releaseTarget())
    }

    func testEscapeDelegatesToAppEvenWithoutHotkeyRecordingState() {
        let manager = HotkeyManager()
        var callCount = 0
        manager.onESCAbort = {
            callCount += 1
            return true
        }

        XCTAssertTrue(manager.handleEscapeAbort())
        XCTAssertEqual(callCount, 1)
    }
}
