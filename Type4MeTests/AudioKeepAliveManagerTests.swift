import XCTest
@testable import Type4Me

final class AudioKeepAliveManagerTests: XCTestCase {
    func testMicKeepAliveIsDisabledWhenFocusWakeupIsEnabled() {
        XCTAssertFalse(AudioKeepAliveManager.shouldRunMicKeepAlive(
            micKeepAliveEnabled: true,
            focusWakeupEnabled: true
        ))
    }

    func testMicKeepAliveCanRunWhenFocusWakeupIsDisabled() {
        XCTAssertTrue(AudioKeepAliveManager.shouldRunMicKeepAlive(
            micKeepAliveEnabled: true,
            focusWakeupEnabled: false
        ))
    }

    func testMicKeepAliveStaysOffWhenUserDisabledIt() {
        XCTAssertFalse(AudioKeepAliveManager.shouldRunMicKeepAlive(
            micKeepAliveEnabled: false,
            focusWakeupEnabled: false
        ))
    }
}
