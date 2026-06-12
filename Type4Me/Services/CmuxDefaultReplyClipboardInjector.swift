import AppKit
import CoreGraphics

protocol CmuxDefaultReplyInjecting: Sendable {
    /// Submits a default reply into the currently focused terminal.
    ///
    /// Args:
    ///   reply: Reply text to type before pressing Return.
    func submit(reply: String)
}

final class CmuxDefaultReplyClipboardInjector: CmuxDefaultReplyInjecting, @unchecked Sendable {
    enum SubmissionAction: Equatable, Sendable {
        case writeClipboard(String)
        case key(keyCode: CGKeyCode, flags: CGEventFlags)
    }

    private struct ClipboardItem: @unchecked Sendable {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private struct ClipboardSnapshot: @unchecked Sendable {
        private static let safeTypes: [NSPasteboard.PasteboardType] = [
            .string,
            .URL,
            .html,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-plain-text"),
            NSPasteboard.PasteboardType("public.url"),
        ]

        let items: [ClipboardItem]

        /// Captures safe pasteboard contents before temporary Go injection.
        ///
        /// Returns:
        ///   Snapshot containing text-like pasteboard items that can be restored safely.
        static func capture() -> ClipboardSnapshot {
            let safeSet = Set(safeTypes.map(\.rawValue))
            let items = (NSPasteboard.general.pasteboardItems ?? []).compactMap { item -> ClipboardItem? in
                let safeItemTypes = item.types.filter { safeSet.contains($0.rawValue) }
                guard !safeItemTypes.isEmpty else { return nil }
                var data: [NSPasteboard.PasteboardType: Data] = [:]
                for type in safeItemTypes {
                    data[type] = item.data(forType: type)
                }
                return ClipboardItem(types: safeItemTypes, data: data)
            }
            return ClipboardSnapshot(items: items)
        }

        /// Restores the captured pasteboard contents when the clipboard is untouched.
        ///
        /// Args:
        ///   expectedChangeCount: Pasteboard change count after MyType wrote the temporary text.
        func restore(expectedChangeCount: Int) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearContents()
            for item in items {
                let pasteboardItem = NSPasteboardItem()
                for type in item.types {
                    guard let data = item.data[type] else { continue }
                    pasteboardItem.setData(data, forType: type)
                }
                pasteboard.writeObjects([pasteboardItem])
            }
        }
    }

    private let eventPoster: @Sendable (CGEvent) -> Void
    private let sleeper: @Sendable (useconds_t) -> Void

    /// Creates an injector that submits Go through a transient clipboard paste.
    ///
    /// Args:
    ///   eventPoster: Event sink used by tests or by the production HID event tap.
    ///   sleeper: Sleep function used between paste, Return, and clipboard restore.
    init(eventPoster: @escaping @Sendable (CGEvent) -> Void = { event in
        event.post(tap: .cghidEventTap)
    }, sleeper: @escaping @Sendable (useconds_t) -> Void = { micros in
        usleep(micros)
    }) {
        self.eventPoster = eventPoster
        self.sleeper = sleeper
    }

    /// Pastes the reply and presses Return in the focused terminal.
    ///
    /// Args:
    ///   reply: Reply text to type before pressing Return.
    func submit(reply: String) {
        guard !reply.isEmpty else { return }
        let snapshot = ClipboardSnapshot.capture()
        var restoreChangeCount: Int?

        for action in Self.submissionActions(for: reply) {
            switch action {
            case .writeClipboard(let text):
                restoreChangeCount = writeTransientClipboard(text)
                sleeper(50_000)
            case .key(let keyCode, let flags):
                post(keyCode: keyCode, flags: flags)
                sleeper(120_000)
            }
        }

        if let restoreChangeCount {
            sleeper(250_000)
            snapshot.restore(expectedChangeCount: restoreChangeCount)
        }
    }

    /// Builds submission actions for a default reply followed by Return.
    ///
    /// Args:
    ///   reply: Reply text to paste.
    ///
    /// Returns:
    ///   Clipboard write, Command-V, and Return actions.
    static func submissionActions(for reply: String) -> [SubmissionAction] {
        [
            .writeClipboard(reply),
            .key(keyCode: 9, flags: .maskCommand),
            .key(keyCode: 36, flags: []),
        ]
    }

    /// Posts one key-down and key-up pair.
    ///
    /// Args:
    ///   keyCode: CoreGraphics key code.
    ///   flags: Modifier flags to apply to the key event.
    private func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        eventPoster(keyDown)
        eventPoster(keyUp)
    }

    /// Writes temporary text to the pasteboard with a transient marker.
    ///
    /// Args:
    ///   text: Text to paste into the terminal.
    ///
    /// Returns:
    ///   Pasteboard change count after writing.
    private func writeTransientClipboard(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        return pasteboard.changeCount
    }
}
