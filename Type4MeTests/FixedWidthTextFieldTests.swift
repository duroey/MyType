import SwiftUI
import XCTest
@testable import Type4Me

@MainActor
final class FixedWidthTextFieldTests: XCTestCase {
    func testEditingEndedCallbackReceivesFinalText() {
        var text = "1.0"
        var endedText: String?
        let binding = Binding(
            get: { text },
            set: { text = $0 }
        )
        let field = FixedWidthTextField(
            text: binding,
            placeholder: "1.0",
            onEditingEnded: { endedText = $0 }
        )
        let coordinator = field.makeCoordinator()
        let nsField = NSTextField()
        nsField.stringValue = "1.7"

        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: nsField)
        )

        XCTAssertEqual(text, "1.7")
        XCTAssertEqual(endedText, "1.7")
    }

    func testReturnKeyCommitsAndConsumesEditingCommand() {
        var text = "1.0"
        var endedText: String?
        let binding = Binding(
            get: { text },
            set: { text = $0 }
        )
        let field = FixedWidthTextField(
            text: binding,
            placeholder: "1.0",
            commitOnReturnOrOutsideClick: true,
            onEditingEnded: { endedText = $0 }
        )
        let coordinator = field.makeCoordinator()
        let nsField = NSTextField()
        let editor = NSTextView()
        editor.string = "2.3"

        let handled = coordinator.control(
            nsField,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(text, "2.3")
        XCTAssertEqual(endedText, "2.3")
        XCTAssertEqual(nsField.stringValue, "2.3")
    }
}
