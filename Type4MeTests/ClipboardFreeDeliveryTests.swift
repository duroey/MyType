import ApplicationServices
import XCTest
@testable import Type4Me

final class ClipboardFreeDeliveryTests: XCTestCase {
    /// Optional verification preserves a precise correction target after immediate send feedback.
    func testDeferredVerificationPreservesConfirmedContext() async {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        target.observe = { target.unicodeCalls > 0 ? .inserted : .unchanged }
        let transaction = ClipboardFreeDeliveryTransaction(wait: { _ in })
        let result = TrackedInjectionResult(
            outcome: TextInjectionEngine.deliveryOutcome(transaction.deliver(to: target)),
            observationContext: nil,
            deferredObservation: {
                transaction.verifyInsertion(to: target) ? Self.trackingContext() : nil
            })
        XCTAssertEqual(result.outcome, .inputDispatched)
        XCTAssertNil(result.observationContext)
        let context = await result.resolveObservationContext()
        XCTAssertEqual(context?.baselineValue, "confirmed text")
        XCTAssertEqual(context?.sourceRecordID, "confirmed-record")
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
        XCTAssertEqual(result.outcome, .inputDispatched)
    }

    /// Cancellation reaches an already-running receipt and discards even a late valid context.
    func testCancellationReachesRunningVerification() async {
        let started = expectation(description: "receipt started")
        let released = DispatchSemaphore(value: 0)
        let result = TrackedInjectionResult(outcome: .inputDispatched, observationContext: nil,
                                           deferredObservation: {
            started.fulfill()
            _ = released.wait(timeout: .now() + 1)
            XCTAssertTrue(Task.isCancelled)
            return Self.trackingContext()
        })
        let verification = Task { await result.resolveObservationContext() }
        await fulfillment(of: [started], timeout: 1)
        verification.cancel()
        released.signal()
        let context = await verification.value
        XCTAssertNil(context)
        XCTAssertEqual(result.outcome, .inputDispatched)
    }

    /// Creates an inert tracking fixture without reading any live application or input field.
    private static func trackingContext() -> TrackedInjectionContext {
        TrackedInjectionContext(
            element: AXUIElementCreateSystemWide(), processIdentifier: 1234,
            bundleIdentifier: "com.example.fixture", baselineValue: "confirmed text",
            injectedRange: NSRange(location: 0, length: 14), beforeSelectedRange: nil,
            afterSelectedRange: nil, placeholderCandidates: [], sourceText: "confirmed text",
            injectedText: "confirmed text", sourceRecordID: "confirmed-record", modeID: UUID()
        )
    }

    /// A slow optional receipt starts only when requested, leaving completion immediately available.
    func testTrackingIsLazyAndCannotChangeCompletion() async {
        let started = expectation(description: "optional tracking started")
        let released = DispatchSemaphore(value: 0)
        let result = TrackedInjectionResult(outcome: .inputDispatched, observationContext: nil,
                                           deferredObservation: {
            started.fulfill()
            _ = released.wait(timeout: .now() + 1)
            return nil
        })
        XCTAssertEqual(result.outcome, .inputDispatched)
        XCTAssertFalse(result.outcome.requiresAttention)
        let verification = Task { await result.resolveObservationContext() }
        await fulfillment(of: [started], timeout: 1)
        // Even while the editor is unresponsive, completion has already been returned.
        XCTAssertEqual(result.outcome, .inputDispatched)
        released.signal()
        let context = await verification.value
        XCTAssertNil(context)
        XCTAssertEqual(result.outcome, .inputDispatched)
    }

    /// A newer session can cancel a queued receipt without publishing stale correction context.
    func testCancelledTrackingDoesNotReadEditor() async {
        let result = TrackedInjectionResult(outcome: .inputDispatched, observationContext: nil,
                                           deferredObservation: {
            XCTFail("Cancelled tracking must not read the editor")
            return nil
        })
        let verification = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await result.resolveObservationContext()
        }
        let context = await verification.value
        XCTAssertNil(context)
        XCTAssertEqual(result.outcome, .inputDispatched)
    }

    /// Enter, further typing and focus changes after a complete send cannot delay or fail completion.
    func testCompletionDoesNotReadOrWaitAfterDispatch() {
        for afterSend in [TextDeliveryObservation.unchanged, .selectionChanged, .changed,
                          .unavailable, .targetChanged, .inserted] {
            for useDirect in [false, true] {
                let target = StubClipboardFreeTarget()
                if useDirect { target.directResult = .dispatched }
                else { target.unicodeResult = .dispatched }
                var postSendReads = 0
                var waits = 0
                target.observe = {
                    let sent = useDirect ? target.directCalls > 0 : target.unicodeCalls > 0
                    guard sent else { return .unchanged }
                    postSendReads += 1
                    return afterSend
                }
                let result = ClipboardFreeDeliveryTransaction(wait: { _ in waits += 1 }).deliver(to: target)
                XCTAssertEqual(result, .inputDispatched)
                XCTAssertFalse(TextInjectionEngine.deliveryOutcome(result).requiresAttention)
                XCTAssertEqual(postSendReads, 0)
                XCTAssertEqual(waits, 0)
                XCTAssertEqual(target.unicodeCalls, 1)
                XCTAssertEqual(target.directCalls, useDirect ? 1 : 0)
            }
        }
    }

    /// Unresolved floating focus cannot fall through into MyType's cached first responder.
    func testUncertainFocusCannotInsertIntoOwnApp() {
        XCTAssertFalse(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: nil, ownPID: 123))
        XCTAssertFalse(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: 456, ownPID: 123))
        XCTAssertTrue(TextInjectionEngine.mayInsertIntoOwnApp(targetPID: 123, ownPID: 123))
    }

    /// Complete dispatch has normal feedback while ambiguous writes retain their warning.
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
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputDispatched).completionMessage, "已完成")
        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputAttempted).completionMessage,
                       "Input unconfirmed")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inserted).completionMessage, "Done")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputDispatched).completionMessage, "Done")
        XCTAssertEqual(TextInjectionEngine.deliveryOutcome(.inputDispatched), .inputDispatched)
        XCTAssertFalse(InjectionOutcome.inputDispatched.requiresAttention)
        XCTAssertTrue(InjectionOutcome.inputAttempted.requiresAttention)
        XCTAssertTrue(InjectionOutcome.actionFailed("failure").requiresAttention)
        XCTAssertFalse(InjectionOutcome.inserted.requiresAttention)
    }

    /// A complete send is normal completion even when the editor cannot supply an exact receipt.
    func testCompleteDispatchDoesNotRaiseFalseWarnings() {
        let previous = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        for observation in [TextDeliveryObservation.changed, .unavailable] {
            for useDirect in [false, true] {
                let target = StubClipboardFreeTarget()
                if useDirect { target.directResult = .dispatched }
                else { target.unicodeResult = .dispatched }
                target.observe = {
                    let sent = useDirect ? target.directCalls > 0 : target.unicodeCalls > 0
                    return sent ? observation : .unchanged
                }
                let result = ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target)
                let outcome = TextInjectionEngine.deliveryOutcome(result)
                XCTAssertNotEqual(outcome, .inserted)
                XCTAssertFalse(outcome.requiresAttention)
                UserDefaults.standard.set("zh", forKey: "tf_language")
                XCTAssertEqual(outcome.completionMessage, "已完成")
                UserDefaults.standard.set("en", forKey: "tf_language")
                XCTAssertEqual(outcome.completionMessage, "Done")
                XCTAssertEqual(target.unicodeCalls, 1)
                XCTAssertEqual(target.directCalls, useDirect ? 1 : 0)
            }
        }
    }

    /// A caret-only receipt does not prove insertion, but cannot reverse a completed send.
    func testCaretMovementDoesNotCreateAFalseFailure() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        let caretOnly = NativeTextDeliveryTarget.compareReceipt(
            beforeValue: "before", beforeRange: NSRange(location: 6, length: 0),
            expectedValue: "before new", insertedUTF16Length: 4,
            currentValue: "before", currentRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(caretOnly, .selectionChanged)
        target.observe = { target.unicodeCalls > 0 ? caretOnly : .unchanged }
        let transaction = ClipboardFreeDeliveryTransaction(wait: { _ in })
        let result = transaction.deliver(to: target)
        XCTAssertEqual(result, .inputDispatched)
        XCTAssertFalse(transaction.verifyInsertion(to: target))
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
    }

    /// Moving the caret before dispatch cannot redirect input into a different selection.
    func testSelectionChangeBeforeSendDoesNotDispatch() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        target.observe = { .selectionChanged }
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .notDelivered)
        XCTAssertEqual(target.unicodeCalls + target.directCalls, 0)
    }
    /// Opaque receivers can consume queued text later without any clipboard dependency.
    func testOpaqueDeliveryDoesNotRetryAfterDispatch() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputDispatched)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
    }

    /// An unavailable event source can use AX, but an ambiguous write is never repeated.
    func testDirectFallbackRequiresNoPriorDispatch() {
        let target = StubClipboardFreeTarget()
        target.directResult = .dispatched
        target.observe = { target.directCalls > 0 ? .inserted : .unchanged }
        XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputDispatched)
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

    /// Old or unreadable AX values cannot diagnose a failure after events were fully sent.
    func testStaleReceiptsDoNotFailCompletion() {
        for observation in [TextDeliveryObservation.unchanged, .unavailable] {
            let target = StubClipboardFreeTarget()
            target.unicodeResult = .dispatched
            target.observe = { observation }
            XCTAssertEqual(ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target), .inputDispatched)
            XCTAssertEqual(target.unicodeCalls, 1)
            XCTAssertEqual(target.directCalls, 0)
        }
    }

    /// Submitting or leaving after a complete send only abandons optional tracking.
    func testPostSendChangesDoNotOverrideCompletion() {
        for observation in [TextDeliveryObservation.targetChanged, .changed] {
            let target = StubClipboardFreeTarget()
            target.unicodeResult = .dispatched
            target.observe = { target.unicodeCalls == 0 ? .unchanged : observation }
            let transaction = ClipboardFreeDeliveryTransaction(wait: { _ in })
            let result = transaction.deliver(to: target)
            XCTAssertFalse(transaction.verifyInsertion(to: target))
            XCTAssertEqual(TextInjectionEngine.deliveryOutcome(result), .inputDispatched)
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
        for (observation, expected) in [(TextDeliveryObservation.unavailable, TextDeliveryResult.inputAttempted),
                                         (.changed, .inputAttempted)] {
            let target = StubClipboardFreeTarget()
            target.directResult = .uncertain
            target.observe = { target.directCalls > 0 ? observation : .unchanged }
            let result = ClipboardFreeDeliveryTransaction(wait: { _ in }).deliver(to: target)
            XCTAssertEqual(result, expected)
            XCTAssertTrue(TextInjectionEngine.deliveryOutcome(result).requiresAttention)
            XCTAssertEqual(target.unicodeCalls, 1)
            XCTAssertEqual(target.directCalls, 1)
        }
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

    /// Optional verification can still confirm delayed rendering without another write.
    func testDelayedReceiptConfirmsTrackingWithoutChangingCompletion() {
        let target = StubClipboardFreeTarget()
        target.directResult = .dispatched
        var waited = false
        target.observe = { waited ? .inserted : .unchanged }
        let transaction = ClipboardFreeDeliveryTransaction(wait: { _ in waited = true })
        let result = transaction.deliver(to: target)
        XCTAssertEqual(result, .inputDispatched)
        XCTAssertFalse(waited)
        XCTAssertTrue(transaction.verifyInsertion(to: target))
        XCTAssertEqual(result, .inputDispatched)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 1)
    }

    /// An editor can expose intermediate text before the queued input is fully rendered.
    func testIntermediateContentChangeWaitsForExactReceiptWithoutRetry() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        var pollsWaited = 0
        target.observe = {
            if target.unicodeCalls == 0 { return .unchanged }
            return pollsWaited >= 2 ? .inserted : .changed
        }
        let transaction = ClipboardFreeDeliveryTransaction(wait: { _ in pollsWaited += 1 })
        let result = transaction.deliver(to: target)
        XCTAssertEqual(result, .inputDispatched)
        XCTAssertEqual(pollsWaited, 0)
        XCTAssertTrue(transaction.verifyInsertion(to: target))
        XCTAssertEqual(pollsWaited, 2)
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
    }

    /// Waiting for an intermediate value must stop when the user leaves the original field.
    func testIntermediateContentDoesNotHideLaterFocusChange() {
        let target = StubClipboardFreeTarget()
        target.unicodeResult = .dispatched
        var waited = false
        target.observe = {
            if target.unicodeCalls == 0 { return .unchanged }
            return waited ? .targetChanged : .changed
        }
        let transaction = ClipboardFreeDeliveryTransaction(wait: { _ in waited = true })
        XCTAssertEqual(transaction.deliver(to: target), .inputDispatched)
        XCTAssertFalse(transaction.verifyInsertion(to: target))
        XCTAssertEqual(target.unicodeCalls, 1)
        XCTAssertEqual(target.directCalls, 0)
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
