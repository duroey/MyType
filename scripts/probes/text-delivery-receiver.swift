import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Supplies only the synthetic event marker needed by the production delivery target.
enum TextInjectionEngine {
    static let marker: Int64 = 0x4D5954595045

    /// Tags a real test key event without replacing any production delivery decisions.
    static func markAsSyntheticInput(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }
}

/// Captures production diagnostics without ever recording user input.
enum DebugFileLogger {
    /// Emits only delivery-path messages produced by the compiled production sources.
    static func log(_ message: String) {
        print(message)
    }
}

struct ReceiverConfiguration {
    var output = "dist/clipboard-regression-20261014/native-receiver-result.json"
    var delayedReadSeconds = 0.55
    var timeoutSeconds = 10.0
    var caseTimeoutSeconds = 3.0
    var settleSeconds = 0.15
    var transport = "clipboard"

    /// Parses optional artifact and timing arguments while enforcing a ten-second run limit.
    static func parse(_ arguments: [String]) throws -> Self {
        var value = Self()
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw NSError(domain: "Missing argument value", code: 1) }
            let key = arguments[index]
            let argument = arguments[index + 1]
            switch key {
            case "--output": value.output = argument
            case "--delayed-read-seconds": value.delayedReadSeconds = Double(argument) ?? -1
            case "--timeout-seconds": value.timeoutSeconds = Double(argument) ?? -1
            case "--case-timeout-seconds": value.caseTimeoutSeconds = Double(argument) ?? -1
            case "--settle-seconds": value.settleSeconds = Double(argument) ?? -1
            case "--transport": value.transport = argument
            default: throw NSError(domain: "Unknown argument: \(key)", code: 1)
            }
            index += 2
        }
        guard value.delayedReadSeconds > 0.4, value.delayedReadSeconds < value.caseTimeoutSeconds,
              value.timeoutSeconds > 0, value.timeoutSeconds <= 10,
              value.caseTimeoutSeconds > 0, value.caseTimeoutSeconds * 2 < value.timeoutSeconds,
              value.settleSeconds > 0, value.settleSeconds < 0.5,
              ["clipboard", "unicode"].contains(value.transport)
        else { throw NSError(domain: "Invalid receiver timing limits", code: 1) }
        return value
    }
}

/// Adds a final probe-window safety check while forwarding every operation to production code.
final class GuardedNativeTarget: TextDeliveryTarget, ClipboardFreeTextDeliveryTarget {
    private let native: NativeTextDeliveryTarget
    private let ownsReceiver: () -> Bool

    /// Wraps the real target only to prevent events from escaping the dedicated receiver.
    init(native: NativeTextDeliveryTarget, ownsReceiver: @escaping () -> Bool) {
        self.native = native
        self.ownsReceiver = ownsReceiver
    }

    /// Requires the production focus check and the dedicated receiver's own focus check.
    func isCurrent() -> Bool { ownsReceiver() && native.isCurrent() }

    /// Uses the production accessibility receipt unchanged while the receiver still owns focus.
    func observation() -> TextDeliveryObservation {
        ownsReceiver() ? native.observation() : .targetChanged
    }

    /// Forwards a native menu action only if the probe's field remains focused.
    func pasteUsingMenu(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        native.pasteUsingMenu { self.ownsReceiver() && shouldDispatch() }
    }

    /// Forwards direct insertion only if the probe's field remains focused.
    func insertDirectly(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        // AX against our own process executes AppKit in-process; keep that mutation on its UI thread.
        // Production targets are separate processes and receive normal accessibility IPC.
        withoutActuallyEscaping(shouldDispatch) { check in
            let insert = { self.native.insertDirectly { self.ownsReceiver() && check() } }
            return Thread.isMainThread ? insert() : DispatchQueue.main.sync(execute: insert)
        }
    }

    /// Forwards real production key posting only if the probe's field remains focused.
    func pasteUsingShortcut(shouldDispatch: () -> Bool) -> Bool {
        native.pasteUsingShortcut { self.ownsReceiver() && shouldDispatch() }
    }

    /// Forwards Unicode events only while this receiver owns its exact input field.
    func insertUsingUnicode(shouldDispatch: () -> Bool) -> TextDeliveryAttempt {
        native.insertUsingUnicode { self.ownsReceiver() && shouldDispatch() }
    }
}

final class ReceiverTextView: NSTextView {
    weak var receiver: ReceiverController?

    /// Reads the uniquely named private pasteboard only after the test's configured delay.
    override func paste(_ sender: Any?) {
        receiver?.receivePaste()
    }

    /// Records receiver-side insertion from actual AppKit text processing.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        receiver?.receiveTextEvent()
    }
}

@MainActor
final class ReceiverController: NSObject, NSApplicationDelegate {
    private let configuration: ReceiverConfiguration
    private let previousApplication: NSRunningApplication?
    private let privatePasteboard: NSPasteboard
    private let nonce = UUID().uuidString
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var window: NSWindow!
    private var textView: ReceiverTextView!
    private var inputMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var finished = false
    private var armed = false
    private var caseIndex = -1
    private var caseStartedAt = 0.0
    private var expectedText = ""
    private var oldText = ""
    private var pasteCalls = 0
    private var keyDowns = 0
    private var keyUps = 0
    private var readTimes: [Double] = []
    private var transactionResult: String?
    private var evaluationScheduled = false
    private var results: [[String: Any]] = []
    private var initialPasteboardChangeCount = 0

    /// Captures the original foreground app without reading any of its windows or clipboard.
    init(configuration: ReceiverConfiguration) {
        self.configuration = configuration
        previousApplication = NSWorkspace.shared.frontmostApplication
        privatePasteboard = NSPasteboard(name: NSPasteboard.Name("com.mytype.receiver.\(UUID().uuidString)"))
        super.init()
    }

    /// Creates the only input field eligible to receive synthetic test keys.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            finish(reason: "Required existing accessibility or post-event permission unavailable", succeeded: false)
            return
        }
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 150),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MyType 隔离输入验证 · 十秒内自动退出"
        textView = ReceiverTextView(frame: NSRect(x: 16, y: 16, width: 448, height: 118))
        textView.isRichText = false
        textView.isEditable = true
        textView.font = .systemFont(ofSize: 15)
        textView.receiver = self
        window.contentView?.addSubview(textView)
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        editMenu.addItem(paste)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.armed, !self.finished else { return event }
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextInjectionEngine.marker,
                      event.keyCode == (self.configuration.transport == "unicode" ? 0 : 9) else {
                    self.finish(reason: "Non-test input arrived in receiver", succeeded: false)
                    return nil
                }
                if event.type == .keyDown { self.keyDowns += 1 } else { self.keyUps += 1 }
                return event
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.armed else { return }
                self.finish(reason: "Receiver window lost key status", succeeded: false)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.armed,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.finish(reason: "Foreground application changed", succeeded: false)
            }
        })
        let remaining = max(0, configuration.timeoutSeconds - (ProcessInfo.processInfo.systemUptime - startedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.finish(reason: "Global receiver deadline exceeded", succeeded: false)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.settleSeconds) { [weak self] in
            guard let self else { return }
            guard self.ownsReceiver() else {
                self.finish(reason: "Receiver never acquired its own focused field", succeeded: false)
                return
            }
            self.armed = true
            self.startNextCase()
        }
    }

    /// Requires this process, this window and this exact first responder immediately before posting.
    private func ownsReceiver() -> Bool {
        !finished && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && NSApp.keyWindow === window && window?.firstResponder === textView
    }

    /// Starts one production transaction against a private clipboard and the probe's own field.
    private func startNextCase() {
        guard ownsReceiver() else { finish(reason: "Receiver focus changed before case", succeeded: false); return }
        caseIndex += 1
        guard caseIndex < 2 else { finish(reason: "Both native input cases completed", succeeded: true); return }
        let index = caseIndex
        caseStartedAt = ProcessInfo.processInfo.systemUptime
        expectedText = configuration.transport == "unicode"
            ? (index == 0 ? "中文输入 English \(nonce)" : "多行😀👩🏽‍💻\n第二行 with tabs\t末尾 \(nonce)")
            : "MYTYPE_NEW_\(nonce)_\(index)"
        oldText = "MYTYPE_OLD_\(nonce)_\(index)"
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        privatePasteboard.clearContents()
        guard privatePasteboard.setString(oldText, forType: .string) else {
            finish(reason: "Private pasteboard could not be initialized", succeeded: false)
            return
        }
        initialPasteboardChangeCount = privatePasteboard.changeCount
        pasteCalls = 0
        keyDowns = 0
        keyUps = 0
        readTimes = []
        transactionResult = nil
        evaluationScheduled = false
        let text = expectedText
        let application = NSRunningApplication.current
        let pasteboard = privatePasteboard
        let transport = configuration.transport
        let checkFocus: @Sendable () -> Bool = { [weak self] in
            let check = { MainActor.assumeIsolated { self?.ownsReceiver() ?? false } }
            return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NativeTextDeliveryTarget(application: application, text: text, configuration: .init())
            let guarded = GuardedNativeTarget(native: target, ownsReceiver: checkFocus)
            let result: TextDeliveryResult
            if transport == "unicode" {
                result = ClipboardFreeDeliveryTransaction().deliver(to: guarded)
            } else {
                result = ClipboardDeliveryTransaction(clipboard: SystemTextDeliveryClipboard(pasteboard: pasteboard))
                    .deliver(text, to: guarded, restoreOriginal: true)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished, self.caseIndex == index else { return }
                self.transactionResult = String(describing: result)
                self.scheduleEvaluationIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.caseTimeoutSeconds) { [weak self] in
            guard let self, !self.finished, self.caseIndex == index else { return }
            self.recordCaseAndContinue(timedOut: true)
        }
    }

    /// Handles AppKit's real Paste action; no general pasteboard or other application's field is accessed.
    func receivePaste() {
        guard ownsReceiver(), armed else { finish(reason: "Paste reached an unfocused receiver", succeeded: false); return }
        pasteCalls += 1
        let index = caseIndex
        let delay = index == 0 ? 0 : configuration.delayedReadSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.finished, self.caseIndex == index else { return }
            guard self.ownsReceiver() else { self.finish(reason: "Focus changed before delayed read", succeeded: false); return }
            let value = self.privatePasteboard.string(forType: .string) ?? ""
            self.readTimes.append(ProcessInfo.processInfo.systemUptime - self.caseStartedAt)
            self.textView.insertText(value, replacementRange: self.textView.selectedRange())
            self.scheduleEvaluationIfReady()
        }
    }

    /// Marks complete Unicode receipt without inspecting or changing the general pasteboard.
    func receiveTextEvent() {
        guard configuration.transport == "unicode", textView.string == expectedText else { return }
        readTimes.append(ProcessInfo.processInfo.systemUptime - caseStartedAt)
        scheduleEvaluationIfReady()
    }

    /// Waits briefly after both real insertion and transaction completion to catch duplicate events.
    private func scheduleEvaluationIfReady() {
        if configuration.transport == "unicode", textView.string == expectedText, readTimes.isEmpty {
            readTimes.append(ProcessInfo.processInfo.systemUptime - caseStartedAt)
        }
        guard transactionResult != nil, !readTimes.isEmpty, !evaluationScheduled else { return }
        evaluationScheduled = true
        let index = caseIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.settleSeconds) { [weak self] in
            guard let self, !self.finished, self.caseIndex == index else { return }
            self.recordCaseAndContinue(timedOut: false)
        }
    }

    /// Records receiver-side evidence, requiring one synthetic key pair and exactly one new marker.
    private func recordCaseAndContinue(timedOut: Bool) {
        let received = textView.string
        let boardText = privatePasteboard.string(forType: .string) ?? ""
        let eventCount = configuration.transport == "unicode"
            ? (NativeTextDeliveryTarget.permitsUnicodeEvents(expectedText)
               ? NativeTextDeliveryTarget.unicodeChunks(expectedText, maximumUTF16Length: 20).count : 0) : 1
        let untouched = privatePasteboard.changeCount == initialPasteboardChangeCount && boardText == oldText
        let passed = !timedOut && pasteCalls == (configuration.transport == "unicode" ? 0 : 1)
            && keyDowns == eventCount && keyUps == eventCount && received == expectedText
            && (configuration.transport != "unicode" || untouched)
        results.append([
            "name": configuration.transport == "unicode"
                ? (caseIndex == 0 ? "unicode-text-events" : "multiline-selected-text")
                : (caseIndex == 0 ? "immediate-private-read" : "delayed-private-read"),
            "passed": passed, "timed_out": timedOut,
            "new_marker": expectedText, "received": received,
            "paste_calls": pasteCalls, "synthetic_key_downs": keyDowns, "synthetic_key_ups": keyUps,
            "read_elapsed_seconds": readTimes,
            "configured_read_delay_seconds": configuration.transport == "unicode" || caseIndex == 0
                ? 0 : configuration.delayedReadSeconds,
            "transaction_result": transactionResult ?? "not-returned",
            "clipboard_restored_to_old": boardText == oldText,
            "clipboard_retains_new": boardText == expectedText,
            "clipboard_untouched": untouched,
            "transport": configuration.transport,
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - caseStartedAt,
        ])
        guard passed else { finish(reason: "Receiver evidence did not confirm exactly one native insertion", succeeded: false); return }
        startNextCase()
    }

    /// Writes only synthetic evidence, releases the private board and restores focus only if still owned.
    private func finish(reason: String, succeeded: Bool) {
        guard !finished else { return }
        let mayRestoreForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        finished = true
        armed = false
        let evidence: [String: Any] = [
            "passed": succeeded, "reason": reason, "nonce": nonce,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "uses_production_native_target": true,
            "uses_production_clipboard_transaction": configuration.transport == "clipboard",
            "uses_production_clipboard_free_transaction": configuration.transport == "unicode",
            "general_clipboard_accessed": false, "target_is_probe_owned_window": true,
            "accessibility_permission_present": AXIsProcessTrusted(),
            "post_event_permission_present": CGPreflightPostEventAccess(),
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - startedAt,
            "cases": results,
        ]
        var exitStatus: Int32 = succeeded ? 0 : 1
        do {
            let output = URL(fileURLWithPath: configuration.output)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            print("Receiver result: \(succeeded ? "PASS" : "FAIL") — \(reason)")
        } catch {
            exitStatus = 2
            fputs("Could not save receiver evidence: \(error)\n", stderr)
        }
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        privatePasteboard.releaseGlobally()
        if mayRestoreForeground, let previousApplication, !previousApplication.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
        window?.orderOut(nil)
        exit(exitStatus)
    }
}

@main
enum TextDeliveryReceiverMain {
    /// Starts the bounded native receiver without requesting any additional system permission.
    @MainActor
    static func main() {
        do {
            let configuration = try ReceiverConfiguration.parse(CommandLine.arguments)
            let app = NSApplication.shared
            setbuf(stdout, nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + configuration.timeoutSeconds) {
                fputs("Receiver watchdog: process deadline reached\n", stderr)
                exit(2)
            }
            app.setActivationPolicy(.regular)
            let controller = ReceiverController(configuration: configuration)
            app.delegate = controller
            withExtendedLifetime(controller) { app.run() }
        } catch {
            fputs("Receiver configuration failed: \(error)\n", stderr)
            exit(2)
        }
    }
}
