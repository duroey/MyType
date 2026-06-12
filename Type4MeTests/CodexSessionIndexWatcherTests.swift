import XCTest
@testable import Type4Me

final class CodexSessionIndexWatcherTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var scheduled: [@Sendable () -> Void] = []
        private(set) var reconcileCount = 0

        /// Records a scheduled debounce callback.
        ///
        /// Args:
        ///   action: Callback scheduled by the watcher.
        func schedule(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            scheduled.append(action)
            lock.unlock()
        }

        /// Records one reconcile call.
        func reconcile() {
            lock.lock()
            reconcileCount += 1
            lock.unlock()
        }

        /// Returns the number of scheduled callbacks.
        ///
        /// Returns:
        ///   Scheduled callback count.
        func scheduledCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return scheduled.count
        }

        /// Runs a scheduled callback by index.
        ///
        /// Args:
        ///   index: Callback index to run.
        func runScheduled(at index: Int) {
            lock.lock()
            let action = scheduled[index]
            lock.unlock()
            action()
        }
    }

    func testSessionEventsAreDebouncedIntoOneReconcile() {
        let recorder = Recorder()
        let watcher = CodexSessionIndexWatcher(
            sessionsRoot: URL(fileURLWithPath: "/tmp/type4me-codex-session-watch-test"),
            debounceDelay: 0.1,
            reconcile: { recorder.reconcile() },
            scheduler: { _, action in recorder.schedule(action) }
        )

        watcher.sessionEventsDidChange()
        watcher.sessionEventsDidChange()

        XCTAssertEqual(recorder.scheduledCount(), 2)
        recorder.runScheduled(at: 0)
        XCTAssertEqual(recorder.reconcileCount, 0)
        recorder.runScheduled(at: 1)
        XCTAssertEqual(recorder.reconcileCount, 1)
    }
}
