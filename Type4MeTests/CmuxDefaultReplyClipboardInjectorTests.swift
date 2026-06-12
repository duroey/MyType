import CoreGraphics
import XCTest
@testable import Type4Me

final class CmuxDefaultReplyClipboardInjectorTests: XCTestCase {
    func testSubmissionActionsPasteGoThenPressReturnWithoutTypingLetters() {
        let actions = CmuxDefaultReplyClipboardInjector.submissionActions(for: "Go")

        XCTAssertEqual(
            actions,
            [
                CmuxDefaultReplyClipboardInjector.SubmissionAction.writeClipboard("Go"),
                CmuxDefaultReplyClipboardInjector.SubmissionAction.key(keyCode: 9, flags: .maskCommand),
                CmuxDefaultReplyClipboardInjector.SubmissionAction.key(keyCode: 36, flags: []),
            ]
        )
    }
}
