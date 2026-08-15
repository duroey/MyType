import XCTest
@testable import Type4Me

final class MicrophoneSelectionPolicyTests: XCTestCase {
    func testUserSelectionStoresConcreteDevice() {
        let result = MicrophoneSelectionPolicy.userSelected("mic-a")

        XCTAssertEqual(result.selectedUID, "mic-a")
        XCTAssertEqual(result.lastUserSelectedUID, "mic-a")
    }

    func testUserSelectionOfSystemDefaultClearsRememberedDevice() {
        let result = MicrophoneSelectionPolicy.userSelected("")

        XCTAssertEqual(result.selectedUID, "")
        XCTAssertEqual(result.lastUserSelectedUID, "")
    }

    func testDisconnectedSelectedDeviceFallsBackToDefaultButKeepsMemory() {
        let result = MicrophoneSelectionPolicy.resolveAfterDeviceRefresh(
            selectedUID: "mic-a",
            lastUserSelectedUID: "mic-a",
            availableUIDs: ["mic-b"]
        )

        XCTAssertEqual(result.selectedUID, "")
        XCTAssertEqual(result.lastUserSelectedUID, "mic-a")
    }

    func testRememberedDeviceIsRestoredWhenItReconnectsFromDefault() {
        let result = MicrophoneSelectionPolicy.resolveAfterDeviceRefresh(
            selectedUID: "",
            lastUserSelectedUID: "mic-a",
            availableUIDs: ["mic-a", "mic-b"]
        )

        XCTAssertEqual(result.selectedUID, "mic-a")
        XCTAssertEqual(result.lastUserSelectedUID, "mic-a")
    }

    func testReconnectDoesNotStealSelectionFromAnotherAvailableDevice() {
        let result = MicrophoneSelectionPolicy.resolveAfterDeviceRefresh(
            selectedUID: "mic-b",
            lastUserSelectedUID: "mic-a",
            availableUIDs: ["mic-a", "mic-b"]
        )

        XCTAssertEqual(result.selectedUID, "mic-b")
        XCTAssertEqual(result.lastUserSelectedUID, "mic-a")
    }

    func testReconnectRefreshWaitsOneSecondForSystemEnumeration() {
        XCTAssertEqual(MicrophoneSelectionPolicy.reconnectRefreshDelaySeconds, 1.0, accuracy: 0.001)
    }
}
