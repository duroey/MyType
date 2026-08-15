import XCTest
@testable import Type4Me

final class HotkeyManagerTests: XCTestCase {
    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var started: [UUID] = []
        private(set) var stopped: [UUID] = []

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
    }

    func testDifferentModifierToggleHotkeyPassesThroughDuringActiveOwner() {
        let manager = HotkeyManager()
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

        sendFlagsChanged(to: manager, keyCode: 54, flags: .maskCommand)
        sendFlagsChanged(to: manager, keyCode: 54, flags: [])
        let passedThrough = sendFlagsChanged(to: manager, keyCode: 61, flags: .maskAlternate)

        XCTAssertEqual(recorder.started, [firstModeId])
        XCTAssertEqual(recorder.stopped, [])
        XCTAssertTrue(passedThrough)
    }

    func testDifferentRegularToggleHotkeyPassesThroughDuringActiveOwner() {
        let manager = HotkeyManager()
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

        sendKeyDown(to: manager, keyCode: 18, flags: .maskCommand)
        let passedThrough = sendKeyDown(to: manager, keyCode: 19, flags: .maskCommand)
        let keyUpPassedThrough = sendKeyUp(to: manager, keyCode: 19, flags: .maskCommand)

        XCTAssertEqual(recorder.started, [firstModeId])
        XCTAssertEqual(recorder.stopped, [])
        XCTAssertTrue(passedThrough)
        XCTAssertTrue(keyUpPassedThrough)
    }

    func testOwnerRegularToggleHotkeyStopsActiveOwner() {
        let manager = HotkeyManager()
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
        let manager = HotkeyManager()
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

    func testNonVoiceKeyDoesNotStopActiveOwner() {
        let manager = HotkeyManager()
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
