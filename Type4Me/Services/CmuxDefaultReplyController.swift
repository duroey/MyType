import AppKit
import Foundation

final class CmuxDefaultReplyController: @unchecked Sendable {
    private static let defaultReply = "Go"
    private static let f20KeyCode: CGKeyCode = 0x5A

    private let defaultReplySender: (String) -> Void

    /// Creates a controller that maps explicit F20 presses to `Go`.
    ///
    /// Args:
    ///   replyInjector: Injector used by the default sender.
    ///   defaultReplySender: Sender used after plain F20 should become `Go`.
    init(
        replyInjector: CmuxDefaultReplyInjecting = CmuxDefaultReplyClipboardInjector(),
        defaultReplySender: ((String) -> Void)? = nil
    ) {
        self.defaultReplySender = defaultReplySender ?? { text in
            Task.detached(priority: .userInitiated) {
                replyInjector.submit(reply: text)
                DebugFileLogger.log("CmuxDefaultReplyController: F20 default reply submitted")
            }
        }
    }

    /// Keeps the voice-insertion callback compatible with the old controller API.
    ///
    /// The new F20 command is explicit, so previous user input no longer affects
    /// default reply behavior.
    func markFocusedSurfaceUserInput() {}

    /// Handles a keyboard event from the global event tap.
    ///
    /// Args:
    ///   type: CoreGraphics event type.
    ///   event: Keyboard event to inspect.
    ///
    /// Returns:
    ///   `true` when MyType handled the event and it should be swallowed.
    func handleKeyboardEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard Self.isF20Key(keyCode),
              Self.isPlainEvent(event) else {
            return false
        }

        defaultReplySender(Self.defaultReply)
        DebugFileLogger.log("CmuxDefaultReplyController: F20 queued default reply")
        return true
    }

    /// Returns whether a key is F20.
    ///
    /// Args:
    ///   keyCode: CoreGraphics virtual key code.
    ///
    /// Returns:
    ///   `true` for F20.
    static func isF20Key(_ keyCode: CGKeyCode) -> Bool {
        keyCode == f20KeyCode
    }

    /// Returns whether a keyboard event has no user-facing modifiers.
    ///
    /// Args:
    ///   event: Keyboard event to inspect.
    ///
    /// Returns:
    ///   `true` when command/control/option/shift are all absent.
    static func isPlainEvent(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
}
