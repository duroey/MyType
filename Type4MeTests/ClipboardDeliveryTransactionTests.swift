import AppKit
import XCTest
@testable import Type4Me

final class ClipboardDeliveryTransactionTests: XCTestCase {
    /// A no-op accessibility menu must not suppress a working system paste event.
    func testSystemPasteRunsBeforeUnreliableAccessibilityCommands() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var received: String?
        target.menu = { .dispatched }
        target.direct = { .dispatched }
        target.shortcut = {
            received = board.pasteboard.string(forType: .string)
            return true
        }
        target.observe = { received == "new" ? .inserted : .unchanged }
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true), .inserted)
        XCTAssertEqual(received, "new")
        XCTAssertEqual(target.shortcutCount, 1)
        XCTAssertEqual(target.menuCount + target.directCount, 0)
    }

    /// A delayed editor must still read this dictation, never the restored old clipboard.
    func testDelayedOpaquePasteKeepsNewText() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var received: String?
        target.shortcut = { true }
        let delivery = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
        let result = delivery.deliver("新的语音", to: target, restoreOriginal: true)
        // The receiver consumes the queued event only after the sender has returned.
        received = board.pasteboard.string(forType: .string)
        XCTAssertEqual(received, "新的语音")
        XCTAssertEqual(result, .pasteAttempted)
        XCTAssertEqual(target.shortcutCount, 1)
    }

    /// A native menu remains a fallback when no keyboard event could be sent.
    func testNativeMenuBypassesBrokenShortcutAndRestoresOnlyAfterReceipt() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var inserted = false
        target.shortcut = { false }
        target.menu = {
            inserted = board.pasteboard.string(forType: .string) == "new"
            return .dispatched
        }
        target.observe = { inserted ? .inserted : .unchanged }
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true)
        XCTAssertTrue(inserted)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.shortcutCount, 1)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "old clipboard")
    }

    /// Direct insertion is available when the application has no accessible Paste menu.
    func testDirectInsertionFallbackDoesNotSendShortcut() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var inserted = false
        target.shortcut = { false }
        target.direct = { inserted = true; return .dispatched }
        target.observe = { inserted ? .inserted : .unchanged }
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.shortcutCount, 1)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "old clipboard")
    }

    /// A slow readable editor keeps clipboard ownership until its insertion is observed.
    func testReadableDelayedPasteRestoresAfterActualConsumption() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var elapsed = 0.0
        var received: String?
        var dispatched = false
        target.shortcut = { dispatched = true; return true }
        target.observe = { received == "new" ? .inserted : .unchanged }
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { delay in
            elapsed += delay
            if dispatched && elapsed >= 0.5 && received == nil {
                received = board.pasteboard.string(forType: .string)
            }
        }).deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(received, "new")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "old clipboard")
    }

    /// Unconfirmed delivery must not trigger a second method and duplicate a late first write.
    func testUnconfirmedMenuDoesNotFallThroughOrRestore() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        target.shortcut = { false }
        target.menu = { .dispatched }
        target.observe = { .unchanged }
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(result, .pasteAttempted)
        XCTAssertEqual(target.directCount, 0)
        XCTAssertEqual(target.shortcutCount, 1)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "new")
    }

    /// Clipboard interference before dispatch cannot cause the wrong text to be pasted.
    func testClipboardChangedBeforeDispatchDoesNotPaste() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var copied = false
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in
            if !copied {
                copied = true
                _ = board.write("user copied this", transient: false)
            }
        }).deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertEqual(target.menuCount + target.directCount + target.shortcutCount, 0)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "user copied this")
    }

    /// A later user copy survives even when the target confirms successful insertion.
    func testConfirmedPasteDoesNotOverwriteLaterUserCopy() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var inserted = false
        target.shortcut = { inserted = true; _ = board.write("user copy", transient: false); return true }
        target.observe = { inserted ? .inserted : .unchanged }
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "user copy")
    }

    /// A failed clipboard write cannot dispatch an event that pastes stale clipboard data.
    func testWriteFailureNeverDispatches() {
        let backing = isolatedClipboard()
        let board = RejectingDeliveryClipboard(backing: backing)
        let target = StubDeliveryTarget()
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(result, .clipboardWriteFailed)
        XCTAssertEqual(target.menuCount + target.directCount + target.shortcutCount, 0)
        XCTAssertEqual(backing.pasteboard.string(forType: .string), "old clipboard")
    }

    /// A focus change before sending retains a recoverable result without typing elsewhere.
    func testFocusChangeBeforeDispatchKeepsNewTextWithoutSending() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        target.current = false
        let result = ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true)
        XCTAssertEqual(result, .clipboardOnly)
        XCTAssertEqual(target.menuCount + target.directCount + target.shortcutCount, 0)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "new")
    }

    /// An explicit retain policy also keeps results after verified delivery.
    func testAlwaysCopyRetainsVerifiedResult() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var inserted = false
        target.shortcut = { inserted = true; return true }
        target.observe = { inserted ? .inserted : .unchanged }
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: false), .inserted)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "new")
    }

    /// An edit made during menu discovery prevents every delivery method from sending.
    func testClipboardChangeDuringMenuDiscoveryStopsDispatch() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        target.shortcut = { false }
        target.beforeMenuDispatch = { _ = board.write("other copy", transient: false) }
        target.menu = { XCTFail("Must not send the replaced clipboard"); return .dispatched }
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true), .clipboardChanged)
        XCTAssertEqual(target.directCount, 0)
        XCTAssertEqual(target.shortcutCount, 1)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "other copy")
    }

    /// A user editing the field during delivery must not cause automatic replacement or retry.
    func testFieldChangedBeforeDispatchStopsAllMethods() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        target.observe = { .changed }
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true), .clipboardOnly)
        XCTAssertEqual(target.menuCount + target.directCount + target.shortcutCount, 0)
    }

    /// Partial or ambiguous insertion preserves recovery text rather than sending it twice.
    func testPartialInsertionNeverRetriesOrRestores() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        var sent = false
        target.shortcut = { sent = true; return true }
        target.observe = { sent ? .changed : .unchanged }
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true), .pasteAttempted)
        XCTAssertEqual(target.directCount + target.menuCount, 0)
        XCTAssertEqual(target.shortcutCount, 1)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "new")
    }

    /// Unsupported input methods leave the current dictation available for a manual paste.
    func testAllMethodsUnavailableLeaveClipboardResult() {
        let board = isolatedClipboard()
        let target = StubDeliveryTarget()
        target.shortcut = { false }
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true), .clipboardOnly)
        XCTAssertEqual(board.pasteboard.string(forType: .string), "new")
    }

    /// Tests use private pasteboards and never replace the user's system clipboard.
    func testSameTextCopiedAfterWriteDoesNotBelongToDelivery() {
        let backing = isolatedClipboard()
        let target = StubDeliveryTarget()
        let board = SameTextRaceClipboard(backing: backing)
        XCTAssertEqual(ClipboardDeliveryTransaction(clipboard: board, wait: { _ in })
            .deliver("new", to: target, restoreOriginal: true), .clipboardChanged)
        XCTAssertEqual(target.menuCount + target.directCount + target.shortcutCount, 0)
        XCTAssertEqual(backing.pasteboard.string(forType: .string), "new")
    }

    /// Matching text and a later generation are insufficient without this write's token.
    func testReceiptCannotClaimAnotherSameTextWrite() throws {
        let board = isolatedClipboard()
        let first = try XCTUnwrap(board.write("new", transient: true))
        let second = try XCTUnwrap(board.write("new", transient: false))
        XCTAssertFalse(board.owns("new", receipt: first))
        XCTAssertFalse(board.owns("new", receipt: TextDeliveryClipboardReceipt(
            changeCount: second.changeCount, identifier: first.identifier)))
        XCTAssertTrue(board.owns("new", receipt: second))
    }

    /// Tests use private pasteboards and never replace the user's system clipboard.
    private func isolatedClipboard() -> SystemTextDeliveryClipboard {
        let pasteboard = NSPasteboard(name: .init("MyType.delivery-tests.\(UUID().uuidString)"))
        let clipboard = SystemTextDeliveryClipboard(pasteboard: pasteboard)
        XCTAssertNotNil(clipboard.write("old clipboard", transient: false))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return clipboard
    }
}

final class NativeTextDeliveryPolicyTests: XCTestCase {
    /// Missing AX focus evidence allows system paste but cannot authorize cached-control access.
    func testUnknownFocusDoesNotBlockSystemPasteOrAuthorizeAXReadWrite() {
        XCTAssertTrue(NativeTextDeliveryTarget.FocusEvidence.unknown.permitsSystemPaste)
        XCTAssertFalse(NativeTextDeliveryTarget.FocusEvidence.unknown.permitsControlAccess)
        XCTAssertTrue(NativeTextDeliveryTarget.FocusEvidence.matched.permitsControlAccess)
        XCTAssertFalse(NativeTextDeliveryTarget.FocusEvidence.changed.permitsSystemPaste)
        XCTAssertFalse(NativeTextDeliveryTarget.FocusEvidence.blocked.permitsSystemPaste)
    }

    /// Paste is identified by its command meaning, independently of remapped shortcuts.
    func testMenuRequiresStandardPasteMeaning() {
        XCTAssertTrue(NativeTextDeliveryTarget.isStandardPasteMenuItem(role: "AXMenuItem", isEnabled: true, title: "Paste"))
        XCTAssertTrue(NativeTextDeliveryTarget.isStandardPasteMenuItem(role: "AXMenuItem", isEnabled: true, title: "粘贴"))
        XCTAssertFalse(NativeTextDeliveryTarget.isStandardPasteMenuItem(role: "AXMenuItem", isEnabled: true, title: "Delete"))
        XCTAssertFalse(NativeTextDeliveryTarget.isStandardPasteMenuItem(role: "AXMenuItem", isEnabled: true, title: "Paste and Match Style"))
        XCTAssertFalse(NativeTextDeliveryTarget.isStandardPasteMenuItem(role: "AXMenuItem", isEnabled: false, title: "Paste"))
    }

    /// Opaque custom editors remain usable without exposing their contents to verification.
    func testUnknownRolesAreOpaqueAndSecureControlsAreBlocked() {
        XCTAssertEqual(NativeTextDeliveryTarget.controlAccess(role: "AXGroup", subrole: nil,
            isEnabled: true, isEditable: nil), .opaque)
        XCTAssertEqual(NativeTextDeliveryTarget.controlAccess(role: "AXTextField", subrole: "AXSecureTextField",
            isEnabled: true, isEditable: true), .blocked)
        XCTAssertEqual(NativeTextDeliveryTarget.controlAccess(role: "AXTextArea", subrole: nil,
            isEnabled: true, isEditable: false), .blocked)
        XCTAssertEqual(NativeTextDeliveryTarget.controlAccess(role: "AXTextField", subrole: nil,
            isEnabled: true, isEditable: true, metadataReadable: false), .opaque)
    }

    /// Replacing the same visible text needs a changed caret, not just matching text.
    func testSameTextReplacementRequiresCaretReceipt() {
        let selection = NSRange(location: 0, length: 2)
        XCTAssertEqual(NativeTextDeliveryTarget.compareReceipt(beforeValue: "你好", beforeRange: selection,
            expectedValue: "你好", insertedUTF16Length: 2, currentValue: "你好", currentRange: selection), .unchanged)
        XCTAssertEqual(NativeTextDeliveryTarget.compareReceipt(beforeValue: "你好", beforeRange: selection,
            expectedValue: "你好", insertedUTF16Length: 2, currentValue: "你好",
            currentRange: NSRange(location: 2, length: 0)), .inserted)
        XCTAssertEqual(NativeTextDeliveryTarget.compareReceipt(beforeValue: "你好", beforeRange: selection,
            expectedValue: "你好", insertedUTF16Length: 2, currentValue: "你好", currentRange: nil), .unavailable)
    }

    /// A substring or a partial insertion cannot authorize clipboard restoration.
    func testReceiptRequiresExactResult() {
        XCTAssertEqual(NativeTextDeliveryTarget.compareReceipt(beforeValue: "a", beforeRange: NSRange(location: 1, length: 0),
            expectedValue: "a😀你好", insertedUTF16Length: 4, currentValue: "a😀", currentRange: nil), .changed)
        XCTAssertEqual(NativeTextDeliveryTarget.compareReceipt(beforeValue: "a", beforeRange: NSRange(location: 1, length: 0),
            expectedValue: "a😀你好", insertedUTF16Length: 4, currentValue: "a😀你好", currentRange: nil), .inserted)
    }

    /// Delivery evidence maps to truthful feedback in both supported languages.
    func testFeedbackFollowsCurrentLanguage() {
        let previous = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.clipboardChanged).completionMessage,
            "剪贴板已变化，文本可从历史记录恢复")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.pasteAttempted), .pasteAttemptedClipboardRetained)
        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.clipboardWriteFailed).completionMessage,
            "Could not write to clipboard; recover the text from history")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.pasteAttempted).completionMessage,
            "Paste attempted; text kept in clipboard")
    }
}

private final class StubDeliveryTarget: TextDeliveryTarget {
    var current = true
    var menu: () -> TextDeliveryAttempt = { .unavailable }
    var direct: () -> TextDeliveryAttempt = { .unavailable }
    var shortcut: () -> Bool = { true }
    var observe: () -> TextDeliveryObservation = { .unavailable }
    var beforeMenuDispatch: () -> Void = {}
    var menuCount = 0
    var directCount = 0
    var shortcutCount = 0
    func isCurrent() -> Bool { current }
    func observation() -> TextDeliveryObservation { observe() }
    func pasteUsingMenu(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        menuCount += 1
        beforeMenuDispatch()
        return shouldDispatch() ? menu() : .unavailable
    }
    func insertDirectly(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        directCount += 1
        return shouldDispatch() ? direct() : .unavailable
    }
    func pasteUsingShortcut(shouldDispatch: () -> Bool) -> Bool {
        shortcutCount += 1
        return shouldDispatch() && shortcut()
    }
}

private struct RejectingDeliveryClipboard: TextDeliveryClipboard {
    let backing: SystemTextDeliveryClipboard
    func capture() -> ClipboardSnapshot { backing.capture() }
    func write(_ text: String, transient: Bool) -> TextDeliveryClipboardReceipt? { nil }
    func owns(_ text: String, receipt: TextDeliveryClipboardReceipt) -> Bool { backing.owns(text, receipt: receipt) }
    func restore(_ snapshot: ClipboardSnapshot, changeCount: Int) { backing.restore(snapshot, changeCount: changeCount) }
}

/// Reproduces a clipboard manager republishing identical text before the write returns to its caller.
private struct SameTextRaceClipboard: TextDeliveryClipboard {
    let backing: SystemTextDeliveryClipboard
    func capture() -> ClipboardSnapshot { backing.capture() }
    func write(_ text: String, transient: Bool) -> TextDeliveryClipboardReceipt? {
        let receipt = backing.write(text, transient: transient)
        _ = backing.write(text, transient: false)
        return receipt
    }
    func owns(_ text: String, receipt: TextDeliveryClipboardReceipt) -> Bool { backing.owns(text, receipt: receipt) }
    func restore(_ snapshot: ClipboardSnapshot, changeCount: Int) { backing.restore(snapshot, changeCount: changeCount) }
}
