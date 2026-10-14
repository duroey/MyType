import XCTest
@testable import Type4Me

final class ClipboardFreeDeliveryTests: XCTestCase {
    /// Unresolved floating focus cannot fall through into MyType's cached first responder.
    func testUncertainFocusCannotInsertIntoOwnApp() {
        XCTAssertFalse(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: nil, ownPID: 123))
        XCTAssertFalse(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: 456, ownPID: 123))
        XCTAssertTrue(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: 123, ownPID: 123))
    }

    /// Unconfirmed feedback neither claims a successful insertion nor mentions auto-copying.
    func testUnconfirmedFeedbackInBothLanguages() {
        let previous = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputAttempted).completionMessage,
                       "文字已发送，未能确认输入；可在历史中查看")
        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputAttempted).completionMessage,
                       "Text sent; insertion unconfirmed. Available in history")
    }
    /// Opaque receivers can consume queued text later without any clipboard dependency.
    func testOpaqueDeliveryDoesNotRetryAfterDispatch() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputAttempted)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
    }

    /// An unavailable event source can use AX, but an ambiguous write is never repeated.
    func testDirectFallbackRequiresNoPriorDispatch() {
        let target = StubClipboardFreeTarget()
        target.directResult = .dispatched
        target.observe = { target.directCalls > 0 ? .inserted : .unchanged }
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inserted)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 1)
    }

    /// A changed target must not receive any event or automatic clipboard fallback.
    func testChangedTargetDoesNotDispatch() {
        let target = StubClipboardFreeTarget()
        target.current = false
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .notDelivered)
        XCTAssertEqual(target.unicodeCalls + target.directCalls, 0)
    }

    /// Direct text events preserve surrogate pairs and the complete original string.
    func testUnicodeChunksPreserveEmojiChineseAndLineBreaks() {
        let text = "你好😀👩🏽‍💻\nabc\t" + String(repeating: "汉😀", count: 20)
        let chunks = NativeTextDeliveryTarget.unicodeChunks(text, maximumUTF16Length: 20)
        XCTAssertEqual(Array(chunks.joined()), Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        for chunk in chunks {
            XCTAssertFalse((0xDC00...0xDFFF).contains(chunk.first ?? 0))
            XCTAssertFalse((0xD800...0xDBFF).contains(chunk.last ?? 0))
        }
    }

    /// Keyboard control text must never submit a command or move focus as a fallback.
    func testControlTextRequiresDirectInsertion() {
        XCTAssertFalse(NativeTextDeliveryTarget.permitsUnicodeEvents("first\nsecond"))
        XCTAssertFalse(NativeTextDeliveryTarget.permitsUnicodeEvents("first\tsecond"))
        XCTAssertFalse(NativeTextDeliveryTarget.permitsUnicodeEvents("first\rsecond"))
        XCTAssertTrue(NativeTextDeliveryTarget.permitsUnicodeEvents("你好 👩🏽‍💻 English"))
    }
}

private final class StubClipboardFreeTarget: ClipboardFreeTextDeliveryTarget {
    var current = true
    var unicodeResult: TextDeliveryAttempt = .unavailable
    var directResult: TextDeliveryAttempt = .unavailable
    var unicodeCalls = 0
    var directCalls = 0
    var observe: () -> TextDeliveryObservation = { .unavailable }
    func isCurrent() -> Bool { current }
    func observation() -> TextDeliveryObservation { observe() }
    func insertUsingUnicode(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        guard shouldDispatch() else { return .unavailable }
        unicodeCalls += 1
        return unicodeResult
    }
    func insertDirectly(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        guard shouldDispatch() else { return .unavailable }
        directCalls += 1
        return directResult
    }
}
