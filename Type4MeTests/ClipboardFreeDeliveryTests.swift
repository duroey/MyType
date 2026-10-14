import ApplicationServices
import XCTest
@testable import Type4Me

final class ClipboardFreeDeliveryTests: XCTestCase {
    /// Unresolved floating focus cannot fall through into MyType's cached first responder.
    func testUncertainFocusCannotInsertIntoOwnApp() {
        XCTAssertFalse(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: nil, ownPID: 123))
        XCTAssertFalse(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: 456, ownPID: 123))
        XCTAssertTrue(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: 123, ownPID: 123))
    }

    /// Only confirmed insertion uses the normal completion label, in both product languages.
    func testNormalCompletionFeedbackInBothLanguages() {
        let previous = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputAttempted), .inputAttempted)
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputAttempted).completionMessage,
                       "输入未确认")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inserted).completionMessage, "已完成")
        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputAttempted).completionMessage,
                       "Input unconfirmed")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inserted).completionMessage, "Done")
        XCTAssertTrue(InjectionOutcome.inputAttempted.requiresAttention)
        XCTAssertTrue(InjectionOutcome.actionFailed("failure").requiresAttention)
        XCTAssertFalse(InjectionOutcome.inserted.requiresAttention)
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
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputTargetChanged)
        XCTAssertEqual(target.unicodeCalls + target.directCalls, 0)
    }

    /// A readable field that stayed unchanged is distinct from an unreadable receipt; neither is retried.
    func testUnchangedAndUnavailableReceiptsRemainDistinct() {
        for (observation, expected) in [
            (TextDeliveryObservation.unchanged, TextDeliveryResult.inputUnchanged),
            (.unavailable, .inputAttempted),
        ] {
            let target = StubClipboardFreeTarget()
            target.unicodeResult = .dispatched
            target.observe = { observation }
            XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), expected)
            XCTAssertEqual(target.unicodeCalls, 1)
            XCTAssertEqual(target.directCalls, 0)
            XCTAssertTrue(TextInjectionEngine.deliveryOutcome(expected).requiresAttention)
        }
    }

    /// User changes after dispatch must retain their cause instead of looking like a missing receipt.
    func testFocusAndContentChangesAfterDispatchRemainDistinct() {
        for (observation, expected) in [
            (TextDeliveryObservation.targetChanged, TextDeliveryResult.inputTargetChanged),
            (.changed, .inputChanged),
        ] {
            let target = StubClipboardFreeTarget()
            target.unicodeResult = .dispatched
            target.observe = { target.unicodeCalls == 0 ? .unchanged : observation }
            XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), expected)
            XCTAssertEqual(target.unicodeCalls, 1)
            XCTAssertEqual(target.directCalls, 0)
        }
    }

    /// A truncated event stream must never fall through to a second insertion method.
    func testPartialDispatchIsReportedWithoutRetry() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .partiallyDispatched
        target.observe = { target.unicodeCalls == 0 ? .unchanged : .targetChanged }
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputPartiallyDispatched)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
    }

    /// A late AX timeout may already have applied its write, so uncertainty must survive receipt polling.
    func testAmbiguousDirectWriteDoesNotClaimSuccessOrRetry() {
        let target = StubClipboardFreeTarget()
        target.directResult = .uncertain
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputAttempted)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 1)
    }

    /// An explicit rejection is observable and cannot become a dispatched or completed result.
    func testRejectedDirectWriteRemainsRejected() {
        let target = StubClipboardFreeTarget()
        target.directResult = .rejected
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputRejected)
        XCTAssertEqual(target.directCalls, 1)
        XCTAssertTrue(TextInjectionEngine.deliveryOutcome(.inputRejected).requiresAttention)
    }

    /// Setter timeouts are ambiguous, unlike protocol-level rejection of a write.
    func testAXWriteErrorsDoNotAllCountAsDispatched() {
        XCTAssertEqual(NativeTextDeliveryTarget.classifyAXWrite(.success), .dispatched)
        for error in [AXError.attributeUnsupported, .apiDisabled, .invalidUIElement, .illegalArgument] {
            XCTAssertEqual(NativeTextDeliveryTarget.classifyAXWrite(error), .rejected)
            XCTAssertFalse(NativeTextDeliveryTarget.classifyAXWrite(error).mayHaveDispatched)
        }
        for error in [AXError.cannotComplete, .failure] {
            XCTAssertEqual(NativeTextDeliveryTarget.classifyAXWrite(error), .uncertain)
            XCTAssertTrue(NativeTextDeliveryTarget.classifyAXWrite(error).mayHaveDispatched)
        }
        XCTAssertTrue(TextDeliveryAttempt.partiallyDispatched.mayHaveDispatched)
    }

    /// A delayed receipt can confirm a single uncertain write without any additional dispatch.
    func testDelayedReceiptConfirmsUncertainWrite() {
        let target = StubClipboardFreeTarget()
        target.directResult = .uncertain
        var waited = false
        target.observe = { waited ? .inserted : .unchanged }
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in waited = true }).deliver(to: target), .inserted)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 1)
    }

    /// Distinct failure causes keep short, localized recovery feedback instead of a normal completion.
    func testFailureFeedbackInBothLanguages() {
        let previous = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        let cases: [(TextDeliveryResult, String, String)] = [
            (.inputUnchanged, "未检测到输入，已存历史", "No input observed; saved in history"),
            (.inputTargetChanged, "输入位置已变，已存历史", "Input target changed; saved in history"),
            (.inputChanged, "输入内容已变，请核对", "Input changed; please check"),
            (.inputPartiallyDispatched, "输入中断，已存历史", "Input interrupted; saved in history"),
            (.inputRejected, "无法输入，已存历史", "Could not insert; saved in history"),
        ]
        for (result, chinese, english) in cases {
            UserDefaults.standard.set("zh", forKey: "tf_language")
            XCTAssertEqual(TextInjectionEngine.deliveryOutcome(result).completionMessage, chinese)
            UserDefaults.standard.set("en", forKey: "tf_language")
            XCTAssertEqual(TextInjectionEngine.deliveryOutcome(result).completionMessage, english)
            XCTAssertTrue(TextInjectionEngine.deliveryOutcome(result).requiresAttention)
        }
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
