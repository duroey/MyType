// Minimal XCTest-compatible shim with a runner.
//
// The Command Line Tools ship no XCTest, so on a machine without Xcode the test
// target cannot even be compiled. This file provides just enough of the XCTest
// API for this repository's tests to build, plus a runner that discovers and
// executes them. Use it through `run_tests.py` in this directory; with Xcode
// installed, plain `swift test` remains the reference.
//
// Known differences from real XCTest:
// - Tests run one class per process, in selector order, on the main thread.
// - `async throws` tests cannot be told apart from `async` ones through the
//   Objective-C runtime, so `run_tests.py` derives that list from the sources.
// - Swift Testing (`@Test`) suites are not run here; SwiftPM runs those itself.
@_exported import Foundation
@_exported import AppKit
import ObjectiveC

// MARK: - Failure bookkeeping

public final class XCTShimRecorder: @unchecked Sendable {
    public static let shared = XCTShimRecorder()
    private let lock = NSLock()
    private var failures: [String] = []
    private var skipped = false

    func begin() {
        lock.lock(); defer { lock.unlock() }
        failures = []
        skipped = false
    }

    func fail(_ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        let name = ("\(file)" as NSString).lastPathComponent
        failures.append("\(name):\(line): \(message)")
    }

    func markSkipped() {
        lock.lock(); defer { lock.unlock() }
        skipped = true
    }

    func end() -> (failures: [String], skipped: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (failures, skipped)
    }
}

private func record(_ message: String, _ user: String, file: StaticString, line: UInt) {
    XCTShimRecorder.shared.fail(user.isEmpty ? message : "\(message) - \(user)", file: file, line: line)
}

// MARK: - XCTestCase

@objcMembers
open class XCTestCase: NSObject {
    open var continueAfterFailure: Bool = true
    open var executionTimeAllowance: TimeInterval = 600
    private var teardownBlocks: [() -> Void] = []
    private var asyncTeardownBlocks: [@Sendable () async throws -> Void] = []
    fileprivate var pendingExpectations: [XCTestExpectation] = []

    public required override init() { super.init() }

    open class func setUp() {}
    open class func tearDown() {}
    open func setUp() {}
    open func tearDown() {}
    open func setUp() async throws {}
    open func tearDown() async throws {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}

    @nonobjc open func addTeardownBlock(_ block: @escaping () -> Void) { teardownBlocks.append(block) }
    @nonobjc open func addTeardownBlock(_ block: @escaping @Sendable () async throws -> Void) {
        asyncTeardownBlocks.append(block)
    }

    fileprivate func drainTeardownBlocks() async {
        for block in teardownBlocks.reversed() { block() }
        teardownBlocks = []
        for block in asyncTeardownBlocks.reversed() {
            do { try await block() } catch {
                XCTShimRecorder.shared.fail("teardown block threw \(error)", file: #filePath, line: #line)
            }
        }
        asyncTeardownBlocks = []
    }

    @nonobjc open func expectation(description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        pendingExpectations.append(expectation)
        return expectation
    }

    @nonobjc open func expectation(
        forNotification name: NSNotification.Name,
        object: Any?,
        handler: ((Notification) -> Bool)? = nil
    ) -> XCTestExpectation {
        let expectation = self.expectation(description: name.rawValue)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { note in
            if handler?(note) ?? true {
                expectation.fulfill()
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        return expectation
    }

    @nonobjc open func wait(
        for expectations: [XCTestExpectation],
        timeout: TimeInterval,
        enforceOrder: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let hasInverted = expectations.contains { $0.isInverted }
        while Date() < deadline {
            if !hasInverted, expectations.allSatisfy({ $0.isSatisfied }) { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTestExpectation.report(expectations, timeout: timeout, file: file, line: line)
    }

    @nonobjc open func waitForExpectations(
        timeout: TimeInterval,
        handler: ((Error?) -> Void)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectations = pendingExpectations
        pendingExpectations = []
        wait(for: expectations, timeout: timeout, file: file, line: line)
        handler?(nil)
    }

    @nonobjc open func fulfillment(
        of expectations: [XCTestExpectation],
        timeout: TimeInterval = 60,
        enforceOrder: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        let hasInverted = expectations.contains { $0.isInverted }
        while Date() < deadline {
            if !hasInverted, expectations.allSatisfy({ $0.isSatisfied }) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTestExpectation.report(expectations, timeout: timeout, file: file, line: line)
    }

    @nonobjc open func measure(_ block: () -> Void) { block() }
}

// MARK: - Expectations

open class XCTestExpectation: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    open var isInverted = false
    open var expectedFulfillmentCount = 1
    open var assertForOverFulfill = true
    open var expectationDescription: String

    public init(description: String) { self.expectationDescription = description }

    open func fulfill() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var fulfillmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var isSatisfied: Bool { fulfillmentCount >= expectedFulfillmentCount }

    static func report(_ expectations: [XCTestExpectation], timeout: TimeInterval, file: StaticString, line: UInt) {
        for expectation in expectations {
            if expectation.isInverted {
                if expectation.fulfillmentCount > 0 {
                    XCTShimRecorder.shared.fail(
                        "inverted expectation fulfilled: \(expectation.expectationDescription)", file: file, line: line
                    )
                }
            } else if !expectation.isSatisfied {
                XCTShimRecorder.shared.fail(
                    "expectation timed out after \(timeout)s: \(expectation.expectationDescription)",
                    file: file, line: line
                )
            }
        }
    }
}

// MARK: - Skips

public struct XCTSkip: Error {
    public let message: String?
    public init(_ message: @autoclosure () -> String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        self.message = message()
    }
}

public func XCTSkipIf(_ c: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
    if try c() { throw XCTSkip(m()) }
}

public func XCTSkipUnless(_ c: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
    if try !c() { throw XCTSkip(m()) }
}

// MARK: - Assertions

private func evaluate<T>(_ e: () throws -> T, _ m: () -> String, file: StaticString, line: UInt) -> T? {
    do { return try e() } catch {
        record("expression threw \(error)", m(), file: file, line: line)
        return nil
    }
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    record("XCTFail", message, file: file, line: line)
}

public func XCTAssert(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try e(), m(), file: file, line: line)
}

public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, m, file: file, line: line) else { return }
    if !value { record("XCTAssertTrue failed", m(), file: file, line: line) }
}

public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, m, file: file, line: line) else { return }
    if value { record("XCTAssertFalse failed", m(), file: file, line: line) }
}

public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, m, file: file, line: line) else { return }
    if let value { record("XCTAssertNil failed: \(value)", m(), file: file, line: line) }
}

public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, m, file: file, line: line) else { return }
    if value == nil { record("XCTAssertNotNil failed", m(), file: file, line: line) }
}

public struct XCTShimUnwrapError: Error {}

public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try e() else {
        record("XCTUnwrap failed: nil \(T.self)", m(), file: file, line: line)
        throw XCTShimUnwrapError()
    }
    return value
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, m, file: file, line: line), let rhs = evaluate(b, m, file: file, line: line) else { return }
    if lhs != rhs { record("XCTAssertEqual failed: (\"\(lhs)\") is not equal to (\"\(rhs)\")", m(), file: file, line: line) }
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, m, file: file, line: line), let rhs = evaluate(b, m, file: file, line: line) else { return }
    if abs(lhs - rhs) > accuracy {
        record("XCTAssertEqual failed: (\"\(lhs)\") is not equal to (\"\(rhs)\") +/- (\"\(accuracy)\")", m(), file: file, line: line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, m, file: file, line: line), let rhs = evaluate(b, m, file: file, line: line) else { return }
    if lhs == rhs { record("XCTAssertNotEqual failed: (\"\(lhs)\") is equal to (\"\(rhs)\")", m(), file: file, line: line) }
}

private func compare<T: Comparable>(_ name: String, _ a: () throws -> T, _ b: () throws -> T, _ m: () -> String, file: StaticString, line: UInt, _ test: (T, T) -> Bool) {
    guard let lhs = evaluate(a, m, file: file, line: line), let rhs = evaluate(b, m, file: file, line: line) else { return }
    if !test(lhs, rhs) { record("\(name) failed: (\"\(lhs)\") vs (\"\(rhs)\")", m(), file: file, line: line) }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertGreaterThan", a, b, m, file: file, line: line) { $0 > $1 }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertGreaterThanOrEqual", a, b, m, file: file, line: line) { $0 >= $1 }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertLessThan", a, b, m, file: file, line: line) { $0 < $1 }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertLessThanOrEqual", a, b, m, file: file, line: line) { $0 <= $1 }
}

public func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try e()
        record("XCTAssertThrowsError failed: did not throw", m(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

public func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try e() } catch { record("XCTAssertNoThrow failed: threw \(error)", m(), file: file, line: line) }
}

public func XCTAssertIdentical(_ a: @autoclosure () throws -> AnyObject?, _ b: @autoclosure () throws -> AnyObject?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, m, file: file, line: line), let rhs = evaluate(b, m, file: file, line: line) else { return }
    if lhs !== rhs { record("XCTAssertIdentical failed", m(), file: file, line: line) }
}

public func XCTAssertNotIdentical(_ a: @autoclosure () throws -> AnyObject?, _ b: @autoclosure () throws -> AnyObject?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, m, file: file, line: line), let rhs = evaluate(b, m, file: file, line: line) else { return }
    if lhs === rhs { record("XCTAssertNotIdentical failed", m(), file: file, line: line) }
}

// MARK: - Runner

private final class AsyncBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var thrown: Error?

    func finish(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        finished = true
        thrown = error
    }

    var state: (done: Bool, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (finished, thrown)
    }
}

/// Runs an async operation to completion while keeping the main run loop alive.
private func runBlocking(timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> Void) -> (timedOut: Bool, error: Error?) {
    let box = AsyncBox()
    Task {
        do { try await operation(); box.finish(nil) } catch { box.finish(error) }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let state = box.state
        if state.done { return (false, state.error) }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
    return (true, nil)
}

private struct UncheckedCase: @unchecked Sendable { let value: XCTestCase }

public enum XCTShimRunner {
    /// Upper bound for one async test, async setUp or async tearDown.
    private static let asyncTimeoutSeconds: TimeInterval = 120
    private typealias SyncIMP = @convention(c) (AnyObject, Selector) -> Void
    private typealias ThrowsIMP = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    private typealias AsyncIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    static func testClasses() -> [XCTestCase.Type] {
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return [] }
        defer { free(UnsafeMutableRawPointer(list)) }
        // Walk raw class pointers and compare identities only. Bridging or casting
        // arbitrary runtime classes messages them, and some system proxy classes
        // trap on any message.
        let raw = UnsafeRawPointer(UnsafeMutableRawPointer(list))
            .assumingMemoryBound(to: UnsafeRawPointer.self)
        let target = unsafeBitCast(XCTestCase.self as AnyClass, to: UnsafeRawPointer.self)
        var result: [XCTestCase.Type] = []
        for index in 0..<Int(count) {
            let pointer = raw[index]
            var parent = class_getSuperclass(unsafeBitCast(pointer, to: AnyClass.self))
            while let current = parent {
                if unsafeBitCast(current, to: UnsafeRawPointer.self) == target {
                    result.append(unsafeBitCast(pointer, to: XCTestCase.Type.self))
                    break
                }
                parent = class_getSuperclass(current)
            }
        }
        return result.sorted { NSStringFromClass($0) < NSStringFromClass($1) }
    }

    static func testSelectors(of cls: AnyClass) -> [String] {
        var names: Set<String> = []
        var current: AnyClass? = cls
        while let c = current, ObjectIdentifier(c) != ObjectIdentifier(XCTestCase.self) {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(c, &count) {
                for index in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(methods[index]))
                    if name.hasPrefix("test") { names.insert(name) }
                }
                free(methods)
            }
            current = class_getSuperclass(c)
        }
        return names.sorted()
    }

    /// Entry point used by the host executable after the test bundle is loaded.
    ///
    /// Args:
    ///   asyncThrowing: "Class.method" names of `async throws` tests, which use an
    ///     error-carrying completion handler.
    ///   filter: Optional class names to run; empty runs everything.
    ///   listOnly: Print class names and exit.
    ///
    /// Returns:
    ///   Process exit status (0 when every executed test passed).
    public static func main(asyncThrowing: Set<String>, filter: Set<String>, listOnly: Bool) -> Int32 {
        let classes = testClasses()
        if listOnly {
            for cls in classes { print(shortName(cls)) }
            return 0
        }
        var passed = 0, failed = 0, skipped = 0
        for cls in classes where filter.isEmpty || filter.contains(shortName(cls)) {
            cls.setUp()
            for selectorName in testSelectors(of: cls) {
                let base = baseName(selectorName)
                let label = "\(shortName(cls)).\(base)"
                let outcome = runOne(cls, selectorName: selectorName, isAsyncThrowing: asyncThrowing.contains(label))
                if outcome.skipped {
                    skipped += 1
                    print("SKIP \(label)")
                } else if outcome.failures.isEmpty {
                    passed += 1
                    print("PASS \(label)")
                } else {
                    failed += 1
                    print("FAIL \(label)")
                    for failure in outcome.failures { print("     \(failure)") }
                }
                fflush(stdout)
            }
            cls.tearDown()
        }
        print("SUMMARY passed=\(passed) failed=\(failed) skipped=\(skipped)")
        return failed == 0 ? 0 : 1
    }

    private static func shortName(_ cls: AnyClass) -> String {
        NSStringFromClass(cls).components(separatedBy: ".").last ?? NSStringFromClass(cls)
    }

    private static func baseName(_ selector: String) -> String {
        for suffix in ["WithCompletionHandler:", "AndReturnError:"] where selector.hasSuffix(suffix) {
            return String(selector.dropLast(suffix.count))
        }
        return selector
    }

    private static func handle(_ error: Error, phase: String) {
        if error is XCTSkip {
            XCTShimRecorder.shared.markSkipped()
        } else if !(error is XCTShimUnwrapError) {
            XCTShimRecorder.shared.fail("\(phase) threw \(error)", file: #filePath, line: #line)
        }
    }

    private static func runOne(_ cls: XCTestCase.Type, selectorName: String, isAsyncThrowing: Bool) -> (failures: [String], skipped: Bool) {
        XCTShimRecorder.shared.begin()
        let instance = cls.init()
        let boxed = UncheckedCase(value: instance)
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, selector) else { return ([], true) }
        let imp = method_getImplementation(method)
        let timeout = asyncTimeoutSeconds

        // Same order as XCTest: async setUp, throwing setUp, plain setUp.
        var setUpFailed = false
        let asyncSetUp = runBlocking(timeout: timeout) { try await boxed.value.setUp() }
        if asyncSetUp.timedOut {
            XCTShimRecorder.shared.fail("async setUp timed out", file: #filePath, line: #line); setUpFailed = true
        } else if let error = asyncSetUp.error { handle(error, phase: "setUp"); setUpFailed = true }
        if !setUpFailed {
            do { try instance.setUpWithError() } catch { handle(error, phase: "setUpWithError"); setUpFailed = true }
        }
        if !setUpFailed { instance.setUp() }

        if !setUpFailed {
            if selectorName.hasSuffix("WithCompletionHandler:") {
                let box = AsyncBox()
                let handler: AnyObject
                if isAsyncThrowing {
                    let block: @convention(block) (NSError?) -> Void = { error in box.finish(error) }
                    handler = block as AnyObject
                } else {
                    let block: @convention(block) () -> Void = { box.finish(nil) }
                    handler = block as AnyObject
                }
                unsafeBitCast(imp, to: AsyncIMP.self)(instance, selector, handler)
                let deadline = Date().addingTimeInterval(timeout)
                var finished = false
                while Date() < deadline {
                    let state = box.state
                    if state.done {
                        finished = true
                        if let error = state.error { handle(error, phase: "test") }
                        break
                    }
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
                }
                if !finished {
                    XCTShimRecorder.shared.fail("async test timed out after \(timeout)s", file: #filePath, line: #line)
                }
            } else if selectorName.hasSuffix("AndReturnError:") {
                var error: NSError?
                let ok = unsafeBitCast(imp, to: ThrowsIMP.self)(instance, selector, &error)
                if !ok, let error { handle(error, phase: "test") }
            } else {
                unsafeBitCast(imp, to: SyncIMP.self)(instance, selector)
            }
        }

        instance.tearDown()
        do { try instance.tearDownWithError() } catch { handle(error, phase: "tearDownWithError") }
        let asyncTearDown = runBlocking(timeout: timeout) {
            try await boxed.value.tearDown()
            await boxed.value.drainTeardownBlocks()
        }
        if asyncTearDown.timedOut {
            XCTShimRecorder.shared.fail("async tearDown timed out", file: #filePath, line: #line)
        } else if let error = asyncTearDown.error { handle(error, phase: "tearDown") }

        let result = XCTShimRecorder.shared.end()
        return (result.failures, result.skipped)
    }
}
