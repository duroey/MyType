import XCTest
@testable import Type4Me

final class CmuxDefaultReplyControllerTests: XCTestCase {
    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []

        /// Records a submitted default reply.
        ///
        /// Args:
        ///   text: Default reply text submitted by the controller.
        func submit(_ text: String) {
            lock.lock()
            calls.append(text)
            lock.unlock()
        }
    }

    func testPlainReturnAlwaysPassesThroughInCmux() {
        let sendRecorder = SendRecorder()
        let controller = CmuxDefaultReplyController(
            defaultReplySender: sendRecorder.submit
        )
        let event = makeKeyDown(keyCode: 36)

        let handled = controller.handleKeyboardEvent(type: CGEventType.keyDown, event: event)

        XCTAssertFalse(handled)
        XCTAssertTrue(sendRecorder.calls.isEmpty)
    }

    func testPlainF20SubmitsDefaultReplyInCmux() {
        let sendRecorder = SendRecorder()
        let controller = CmuxDefaultReplyController(
            defaultReplySender: sendRecorder.submit
        )
        let event = makeKeyDown(keyCode: 90)

        let handled = controller.handleKeyboardEvent(type: CGEventType.keyDown, event: event)

        XCTAssertTrue(handled)
        XCTAssertEqual(sendRecorder.calls, ["Go"])
    }

    func testDefaultSenderUsesKeyboardInjector() {
        final class KeyboardRecorder: CmuxDefaultReplyInjecting, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var replies: [String] = []
            let expectation: XCTestExpectation

            init(expectation: XCTestExpectation) {
                self.expectation = expectation
            }

            /// Records a default reply submission.
            ///
            /// Args:
            ///   reply: Reply text submitted by the controller.
            func submit(reply: String) {
                lock.lock()
                replies.append(reply)
                lock.unlock()
                expectation.fulfill()
            }
        }

        let expectation = expectation(description: "keyboard injector submitted Go")
        let keyboardRecorder = KeyboardRecorder(expectation: expectation)
        let controller = CmuxDefaultReplyController(
            replyInjector: keyboardRecorder
        )
        let event = makeKeyDown(keyCode: 90)

        let handled = controller.handleKeyboardEvent(type: CGEventType.keyDown, event: event)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(handled)
        XCTAssertEqual(keyboardRecorder.replies, ["Go"])
    }

    func testPlainF20SubmitsDefaultReplyWithoutFrontmostAppGate() {
        let sendRecorder = SendRecorder()
        let controller = CmuxDefaultReplyController(
            defaultReplySender: sendRecorder.submit
        )
        let event = makeKeyDown(keyCode: 90)

        let handled = controller.handleKeyboardEvent(type: CGEventType.keyDown, event: event)

        XCTAssertTrue(handled)
        XCTAssertEqual(sendRecorder.calls, ["Go"])
    }

    func testModifiedF20PassesThrough() {
        let sendRecorder = SendRecorder()
        let controller = CmuxDefaultReplyController(
            defaultReplySender: sendRecorder.submit
        )
        let event = makeKeyDown(keyCode: 90, flags: .maskCommand)

        let handled = controller.handleKeyboardEvent(type: CGEventType.keyDown, event: event)

        XCTAssertFalse(handled)
        XCTAssertTrue(sendRecorder.calls.isEmpty)
    }

    /// Creates a key-down event for controller tests.
    ///
    /// Args:
    ///   keyCode: CoreGraphics virtual key code.
    ///   flags: Modifier flags attached to the event.
    ///
    /// Returns:
    ///   A key-down event with the requested key code and flags.
    private func makeKeyDown(keyCode: CGKeyCode, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return event
    }
}
