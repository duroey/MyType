import XCTest
@testable import Type4Me

final class HotkeyManagerTests: XCTestCase {
    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var started: [UUID] = []
        private(set) var stopped: [UUID] = []
        private(set) var crossModeFinishes: [UUID] = []
        private(set) var busyConflictCount = 0

        /// Records a mode start callback.
        ///
        /// Args:
        ///   modeId: Mode ID that started.
        func start(_ modeId: UUID) {
            lock.lock()
            started.append(modeId)
            lock.unlock()
        }

        /// Records a mode stop callback.
        ///
        /// Args:
        ///   modeId: Mode ID that stopped.
        func stop(_ modeId: UUID) {
            lock.lock()
            stopped.append(modeId)
            lock.unlock()
        }

        /// Records a cross-mode finish callback.
        ///
        /// Args:
        ///   modeId: Mode ID whose shortcut ended the active recording.
        func crossModeFinish(_ modeId: UUID) {
            lock.lock()
            crossModeFinishes.append(modeId)
            lock.unlock()
        }

        /// Records a rejected attempt to start while processing.
        func busyConflict() {
            lock.lock()
            busyConflictCount += 1
            lock.unlock()
        }
    }

    /// Creates a manager whose event handling does not depend on the test
    /// process holding Accessibility permission.
    ///
    /// Returns:
    ///   A hotkey manager that treats every handled event as trusted.
    private func makeManager() -> HotkeyManager {
        let manager = HotkeyManager()
        manager.isAccessibilityTrusted = { true }
        return manager
    }

    func testDifferentModifierToggleHotkeyFinishesActiveOwnerAndIsConsumed() {
        let manager = makeManager()
        let firstModeId = UUID()
        let secondModeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: firstModeId,
                keyCode: 54,
                modifiers: [],
                onStart: { recorder.start(firstModeId) },
                onStop: { recorder.stop(firstModeId) }
            ),
            makeBinding(
                modeId: secondModeId,
                keyCode: 61,
                modifiers: [],
                onStart: { recorder.start(secondModeId) },
                onStop: { recorder.stop(secondModeId) }
            ),
        ])
        manager.onCrossModeFinish = { recorder.crossModeFinish($0) }

        sendFlagsChanged(to: manager, keyCode: 54, flags: .maskCommand)
        sendFlagsChanged(to: manager, keyCode: 54, flags: [])
        let pressPassedThrough = sendFlagsChanged(to: manager, keyCode: 61, flags: .maskAlternate)
        let releasePassedThrough = sendFlagsChanged(to: manager, keyCode: 61, flags: [])

        XCTAssertEqual(recorder.started, [firstModeId])
        XCTAssertEqual(recorder.stopped, [])
        XCTAssertEqual(recorder.crossModeFinishes, [secondModeId])
        XCTAssertFalse(pressPassedThrough)
        XCTAssertFalse(
            releasePassedThrough,
            "A modifier release that dispatches a hotkey must be swallowed"
        )
    }

    func testDifferentRegularToggleHotkeyFinishesActiveOwnerAndIsConsumed() {
        let manager = makeManager()
        let firstModeId = UUID()
        let secondModeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: firstModeId,
                keyCode: 18,
                modifiers: .maskCommand,
                onStart: { recorder.start(firstModeId) },
                onStop: { recorder.stop(firstModeId) }
            ),
            makeBinding(
                modeId: secondModeId,
                keyCode: 19,
                modifiers: .maskCommand,
                onStart: { recorder.start(secondModeId) },
                onStop: { recorder.stop(secondModeId) }
            ),
        ])
        manager.onCrossModeFinish = { recorder.crossModeFinish($0) }

        sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)
        let passedThrough = sendKeyDown(to: manager, keyCode: 19, flags: .maskCommand)
        let keyUpPassedThrough = sendKeyUp(to: manager, keyCode: 19, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [firstModeId])
        XCTAssertEqual(recorder.stopped, [])
        XCTAssertEqual(recorder.crossModeFinishes, [secondModeId])
        XCTAssertFalse(passedThrough)
        XCTAssertFalse(keyUpPassedThrough)
    }

    func testOwnerRegularToggleHotkeyStopsActiveOwner() {
        let manager = makeManager()
        let modeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: modeId,
                keyCode: 18,
                modifiers: .maskCommand,
                onStart: { recorder.start(modeId) },
                onStop: { recorder.stop(modeId) }
            ),
        ])

        sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)
        let passedThrough = sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [modeId])
        XCTAssertEqual(recorder.stopped, [modeId])
        XCTAssertFalse(passedThrough)
    }

    func testExternalOwnerCanBeStoppedByMatchingHotkey() {
        let manager = makeManager()
        let modeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: modeId,
                keyCode: 18,
                modifiers: .maskCommand,
                onStart: { recorder.start(modeId) },
                onStop: { recorder.stop(modeId) }
            ),
        ])
        manager.setExternalRecordingOwner(modeId: modeId)

        let passedThrough = sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [])
        XCTAssertEqual(recorder.stopped, [modeId])
        XCTAssertFalse(passedThrough)
    }

    /// Verifies that stale processing state cannot block a matching external toggle stop.
    func testProcessingFlagDoesNotBlockMatchingExternalToggleStop() {
        let manager = makeManager()
        let modeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: modeId,
                keyCode: 18,
                modifiers: .maskCommand,
                onStart: { recorder.start(modeId) },
                onStop: { recorder.stop(modeId) }
            ),
        ])
        manager.onBusyConflict = { recorder.busyConflict() }
        manager.setExternalRecordingOwner(modeId: modeId)
        manager.isProcessing = true

        let passedThrough = sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [])
        XCTAssertEqual(recorder.stopped, [modeId])
        XCTAssertEqual(recorder.busyConflictCount, 0)
        XCTAssertFalse(passedThrough)
    }

    /// Verifies that stale processing state cannot block a matching external hold stop.
    func testProcessingFlagDoesNotBlockMatchingExternalHoldStop() {
        let manager = makeManager()
        let modeId = UUID()
        let recorder = CallbackRecorder()
        let binding = ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 18,
            modifiers: .maskCommand,
            style: .hold,
            onStart: { recorder.start(modeId) },
            onStop: { recorder.stop(modeId) }
        )

        manager.registerBindings([binding])
        manager.onBusyConflict = { recorder.busyConflict() }
        manager.setExternalRecordingOwner(modeId: modeId)
        manager.isProcessing = true

        let passedThrough = sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [])
        XCTAssertEqual(recorder.stopped, [modeId])
        XCTAssertEqual(recorder.busyConflictCount, 0)
        XCTAssertFalse(manager.isHoldActive(for: binding.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertFalse(passedThrough)
    }

    /// Verifies that processing still rejects a genuinely new idle recording.
    func testProcessingFlagStillBlocksIdleStart() {
        let manager = makeManager()
        let modeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: modeId,
                keyCode: 18,
                modifiers: .maskCommand,
                onStart: { recorder.start(modeId) },
                onStop: { recorder.stop(modeId) }
            ),
        ])
        manager.onBusyConflict = { recorder.busyConflict() }
        manager.isProcessing = true

        let passedThrough = sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [])
        XCTAssertEqual(recorder.stopped, [])
        XCTAssertEqual(recorder.busyConflictCount, 1)
        XCTAssertFalse(passedThrough)
    }

    /// Verifies that a menu-started Revise recording stops on its first Revise shortcut press.
    func testExternalReviseOwnerStopsOnFirstMatchingHotkeyPress() {
        let manager = makeManager()
        let stoppedOwnerId = UUID()
        let recorder = CallbackRecorder()
        let reviseBinding = ModeBinding(
            bindingId: UUID(),
            owner: .globalAction(.revise),
            keyCode: 20,
            modifiers: .maskCommand,
            style: .toggle,
            onStart: {},
            onStop: { recorder.stop(stoppedOwnerId) }
        )

        manager.registerBindings([reviseBinding])
        manager.setExternalRecordingOwner(owner: .globalAction(.revise))

        let passedThrough = sendKeyDown(to: manager, keyCode: 20, flags: .maskCommand)

        XCTAssertEqual(recorder.stopped, [stoppedOwnerId])
        XCTAssertFalse(passedThrough)
    }

    /// Verifies that a mode shortcut can stop a menu-started Revise recording once.
    func testModeHotkeyStopsExternalReviseOwner() {
        let manager = makeManager()
        let stoppedOwnerId = UUID()
        let targetModeId = UUID()
        let recorder = CallbackRecorder()
        let reviseBinding = ModeBinding(
            bindingId: UUID(),
            owner: .globalAction(.revise),
            keyCode: 20,
            modifiers: .maskCommand,
            style: .toggle,
            onStart: {},
            onStop: { recorder.stop(stoppedOwnerId) }
        )
        let modeBinding = makeBinding(
            modeId: targetModeId,
            keyCode: 21,
            modifiers: .maskCommand,
            onStart: { recorder.start(targetModeId) },
            onStop: { recorder.stop(targetModeId) }
        )

        manager.registerBindings([reviseBinding, modeBinding])
        manager.setExternalRecordingOwner(owner: .globalAction(.revise))

        let passedThrough = sendKeyDown(to: manager, keyCode: 21, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [])
        XCTAssertEqual(recorder.stopped, [stoppedOwnerId])
        XCTAssertFalse(passedThrough)
    }

    func testNonVoiceKeyDoesNotStopActiveOwner() {
        let manager = makeManager()
        let modeId = UUID()
        let recorder = CallbackRecorder()

        manager.registerBindings([
            makeBinding(
                modeId: modeId,
                keyCode: 18,
                modifiers: .maskCommand,
                onStart: { recorder.start(modeId) },
                onStop: { recorder.stop(modeId) }
            ),
        ])
        manager.onKeyboardEvent = { type, event in
            guard type == .keyDown else { return false }
            return CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == 90
        }

        sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)
        sendKeyDown(to: manager, keyCode: 90)
        sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [modeId])
        XCTAssertEqual(recorder.stopped, [modeId])
    }

    /// Creates a toggle-mode hotkey binding for tests.
    ///
    /// Args:
    ///   modeId: Processing mode ID owned by the binding.
    ///   keyCode: CoreGraphics virtual key code.
    ///   modifiers: Required modifier flags for regular-key bindings.
    ///   onStart: Callback invoked when the binding starts recording.
    ///   onStop: Callback invoked when the binding stops recording.
    ///
    /// Returns:
    ///   A toggle binding wired to the provided callbacks.
    private func makeBinding(
        modeId: UUID,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void
    ) -> ModeBinding {
        ModeBinding(
            modeId: modeId,
            keyCode: keyCode,
            modifiers: modifiers,
            style: .toggle,
            onStart: onStart,
            onStop: onStop
        )
    }

    /// Sends a key-down event into the hotkey manager.
    ///
    /// Args:
    ///   manager: Hotkey manager under test.
    ///   keyCode: CoreGraphics virtual key code.
    ///   flags: Modifier flags attached to the event.
    @discardableResult
    private func sendKeyDown(to manager: HotkeyManager, keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return manager.handleEvent(type: .keyDown, event: event) != nil
    }

    /// Sends a key-up event into the hotkey manager.
    ///
    /// Args:
    ///   manager: Hotkey manager under test.
    ///   keyCode: CoreGraphics virtual key code.
    ///   flags: Modifier flags attached to the event.
    ///
    /// Returns:
    ///   True when the event passed through to the system.
    private func sendKeyUp(to manager: HotkeyManager, keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
        event.flags = flags
        return manager.handleEvent(type: .keyUp, event: event) != nil
    }

    /// Sends a flags-changed event into the hotkey manager.
    ///
    /// Args:
    ///   manager: Hotkey manager under test.
    ///   keyCode: CoreGraphics virtual key code.
    ///   flags: Modifier flags attached to the event.
    @discardableResult
    private func sendFlagsChanged(to manager: HotkeyManager, keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return manager.handleEvent(type: .flagsChanged, event: event) != nil
    }
}
