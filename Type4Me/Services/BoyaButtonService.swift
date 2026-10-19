import AppKit
import ApplicationServices
import Darwin
import IOKit.hid
import IOKit.hidsystem
import os

/// Binds the continue shortcut to an exclusively opened BOYA Magic HID interface.
@MainActor
final class BoyaButtonService {
    static let shared = BoyaButtonService()

    private var state: BoyaButtonState = .disabled {
        didSet {
            guard state != oldValue else { return }
            logger.info("BOYA connection state: \(String(describing: self.state), privacy: .public)")
        }
    }
    private var feedback: BoyaButtonFeedback = .none {
        didSet {
            guard feedback != oldValue, feedback != .none else { return }
            logger.info("BOYA action outcome: \(String(describing: self.feedback), privacy: .public)")
        }
    }
    private var lastErrorCode: String? {
        didSet {
            guard lastErrorCode != oldValue, let lastErrorCode else { return }
            logger.error("BOYA connection error: \(lastErrorCode, privacy: .public)")
        }
    }

    private var configuration: BoyaButtonConfiguration?
    private var filter: BoyaButtonEventFilter?
    private var gate: BoyaButtonActionGate?
    private var sender: BoyaButtonActionSender?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var lockDescriptor: Int32 = -1
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var sleeping = false
    private var sessionActive = true
    private let logger = Logger(subsystem: "com.type4me.app", category: "BoyaButton")

    /// Keeps hardware ownership in the application's single shared service.
    private init() {}

    /// Installs bounded discovery and lifecycle observation without sending any keyboard input.
    func start() {
        guard !started else { return }
        do {
            let value = try BoyaButtonConfiguration.bundled()
            sender = try BoyaButtonActionSender(configuration: value)
            configuration = value
            filter = BoyaButtonEventFilter(configuration: value)
            gate = BoyaButtonActionGate(cooldownSeconds: value.cooldownSeconds)
            started = true
            installObservers()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: value.refreshSeconds, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        } catch {
            state = .failed
            lastErrorCode = "configuration"
            logger.error("BOYA configuration could not be loaded: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cancels delayed output and releases hardware, process locks, and lifecycle observers.
    func stop() {
        started = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        disconnect()
        state = .disabled
    }

    /// Observes sleep and console-session transitions without introducing another user setting.
    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions: [(Notification.Name, Bool, Bool)] = [
            (NSWorkspace.willSleepNotification, true, false),
            (NSWorkspace.didWakeNotification, false, false),
            (NSWorkspace.sessionDidResignActiveNotification, true, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, false, true),
        ]
        for (name, suspended, sessionEvent) in transitions {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if sessionEvent { self.sessionActive = !suspended } else { self.sleeping = suspended }
                    self.refresh()
                }
            })
        }
    }

    /// Rejects locked or inactive console sessions before either phase of the shortcut.
    private var sessionUsable: Bool {
        guard !sleeping, sessionActive,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["kCGSSessionOnConsoleKey"] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    /// Rechecks inexpensive gates while connected and enumerates only while disconnected.
    private func refresh() {
        guard started, let configuration else { return }
        guard sessionUsable else { disconnect(); state = .suspended; return }
        if device != nil {
            guard hasPermissions else { disconnect(); state = .permissionRequired; return }
            state = .ready
            return
        }
        let candidateManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(candidateManager, [
            kIOHIDVendorIDKey: configuration.vendorID,
            kIOHIDProductIDKey: configuration.productID,
        ] as CFDictionary)
        let devices = IOHIDManagerCopyDevices(candidateManager) as? Set<IOHIDDevice> ?? []
        guard !devices.isEmpty else { state = .waitingForDevice; return }
        guard devices.count == 1, let candidate = devices.first else { state = .ambiguousDevice; return }
        guard let size = IOHIDDeviceGetProperty(candidate, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber,
              size.intValue > 0, size.intValue <= configuration.maximumInputReportBytes else {
            state = .unsupportedDevice
            return
        }
        guard hasPermissions else { state = .permissionRequired; return }
        guard acquireLock(configuration: configuration) else { return }
        let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            releaseLock()
            lastErrorCode = String(format: "0x%08x", UInt32(bitPattern: result))
            switch result {
            case kIOReturnExclusiveAccess, kIOReturnBusy: state = .occupied
            case kIOReturnNotPermitted, kIOReturnNotPrivileged: state = .permissionRequired
            default: state = .failed
            }
            return
        }
        manager = candidateManager
        device = candidate
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: configuration.maximumInputReportBytes)
        inputBuffer.initialize(repeating: 0, count: configuration.maximumInputReportBytes)
        buffer = inputBuffer
        filter?.reset()
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(candidate, inputBuffer, size.intValue, { context, result, _, type, reportID, bytes, length in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<BoyaButtonService>.fromOpaque(context).takeUnretainedValue()
                    .receive(result: result, type: type, reportID: reportID, bytes: bytes, length: length)
            }
        }, context)
        IOHIDDeviceRegisterRemovalCallback(candidate, { context, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated {
                let service = Unmanaged<BoyaButtonService>.fromOpaque(context).takeUnretainedValue()
                service.disconnect()
                service.state = .waitingForDevice
            }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        lastErrorCode = nil
        state = .ready
    }

    /// Preflights every required permission so built-in discovery never opens a permission prompt.
    private var hasPermissions: Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess()
            && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Consumes exact report bytes and drops all unavailable or repeated hardware actions.
    ///
    /// Args:
    ///   result: IOKit input callback status.
    ///   type: Report category; only input reports can trigger the shortcut.
    ///   reportID: IOKit's report identifier.
    ///   bytes: Callback-owned bytes consumed synchronously on the main run loop.
    ///   length: Actual report size, bounded before accessing its buffer.
    private func receive(
        result: IOReturn, type: IOHIDReportType, reportID: UInt32,
        bytes: UnsafeMutablePointer<UInt8>, length: Int
    ) {
        guard started, device != nil, let configuration else { return }
        guard result == kIOReturnSuccess, type == kIOHIDReportTypeInput,
              length >= 0, length <= configuration.maximumInputReportBytes else {
            lastErrorCode = String(format: "input:0x%08x", UInt32(bitPattern: result))
            disconnect()
            state = .failed
            return
        }
        guard sessionUsable, hasPermissions else { refresh(); return }
        let report = Array(UnsafeBufferPointer(start: bytes, count: length))
        guard filter?.receive(reportID: reportID, bytes: report, uptime: ProcessInfo.processInfo.systemUptime) == true,
              let token = gate?.begin(ready: state == .ready, uptime: ProcessInfo.processInfo.systemUptime),
              let sender else { return }
        feedback = .none
        sender.send(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.started && self.sessionUsable && self.hasPermissions
                && self.device != nil && self.state == .ready && self.gate?.isCurrent(token) == true
        }, completion: { [weak self] result in
            guard let self, self.gate?.isCurrent(token) == true else { return }
            self.feedback = result
            self.gate?.finish(token)
        })
    }

    /// Releases callbacks before their storage, returning the original HID action to macOS.
    private func disconnect() {
        if sender?.cancel() == true { feedback = .returnCancelled }
        gate?.cancel()
        filter?.reset()
        if let device {
            if let buffer, let configuration {
                IOHIDDeviceRegisterInputReportCallback(device, buffer, configuration.maximumInputReportBytes, nil, nil)
            }
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let result = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess {
                logger.error("BOYA HID close returned \(result, privacy: .public)")
            }
        }
        device = nil
        manager = nil
        if let buffer, let configuration {
            buffer.deinitialize(count: configuration.maximumInputReportBytes)
            buffer.deallocate()
        }
        buffer = nil
        releaseLock()
    }

    /// Acquires the standalone BOYA utility's lock before claiming its HID interface.
    ///
    /// Args:
    ///   configuration: Validated shared lock filename and hardware settings.
    /// Returns:
    ///   True while this process holds the lock; failures update its diagnostic state.
    private func acquireLock(configuration: BoyaButtonConfiguration) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(configuration.lockFileName)
        let fd = url.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { lastErrorCode = "lock_open:\(errno)"; state = .failed; return false }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            Darwin.close(fd)
            lastErrorCode = "lock_metadata"
            state = .failed
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            lastErrorCode = "lock:\(code)"
            state = code == EWOULDBLOCK ? .occupied : .failed
            return false
        }
        lockDescriptor = fd
        return true
    }

    /// Closes the shared lock without unlinking an inode another process may already use.
    private func releaseLock() {
        guard lockDescriptor >= 0 else { return }
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }
}
