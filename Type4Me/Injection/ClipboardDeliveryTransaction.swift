import AppKit
import Foundation

enum TextDeliveryObservation: Equatable { case inserted, unchanged, unavailable, changed, targetChanged }
enum TextDeliveryAttempt { case unavailable, dispatched }
enum TextDeliveryResult: Equatable {
    case inserted, pasteAttempted, clipboardOnly, clipboardChanged, clipboardWriteFailed
    case inputAttempted, notDelivered
}

protocol TextDeliveryTarget {
    func isCurrent() -> Bool
    func observation() -> TextDeliveryObservation
    func pasteUsingMenu(shouldDispatch: () -> Bool) -> TextDeliveryAttempt
    func insertDirectly(shouldDispatch: () -> Bool) -> TextDeliveryAttempt
    func pasteUsingShortcut(shouldDispatch: () -> Bool) -> Bool
}

struct TextDeliveryConfiguration: Codable, Sendable {
    var pasteboardSettleSeconds = 0.03
    var verificationTimeoutSeconds = 0.8
    var verificationPollIntervalSeconds = 0.04
    var accessibilityTimeoutSeconds = 0.05
    var maximumValueUTF16Length = 100_000
    var maximumMenuNodes = 128
    var maximumMenuDepth = 4
    var maximumMenuSearchSeconds = 0.2
    var unicodeChunkUTF16Length = 20
    var unicodeChunkIntervalSeconds = 0.005
    var maximumUnicodeDeliverySeconds = 3.0
    var maximumFocusWindowCandidates = 16
    var maximumFocusResolutionSeconds = 0.2
    var minimumFloatingWindowDimension = 48.0
    var focusWindowMatchTolerance = 1.0

    /// Loads bounded delivery timings from the application resource, or development defaults.
    static func bundled(in bundle: Bundle = .main) throws -> Self {
        let value: Self
        if let url = bundle.url(forResource: "TextDeliveryConfig", withExtension: "json") {
            value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } else { value = Self() }
        guard value.pasteboardSettleSeconds.isFinite, (0...0.2).contains(value.pasteboardSettleSeconds),
              value.verificationTimeoutSeconds.isFinite, (0.1...2).contains(value.verificationTimeoutSeconds),
              value.verificationPollIntervalSeconds.isFinite, (0.01...0.2).contains(value.verificationPollIntervalSeconds),
              value.accessibilityTimeoutSeconds.isFinite, (0.01...0.2).contains(value.accessibilityTimeoutSeconds),
              value.maximumMenuSearchSeconds.isFinite, (0.05...0.5).contains(value.maximumMenuSearchSeconds),
              (2...20).contains(value.unicodeChunkUTF16Length),
              value.unicodeChunkIntervalSeconds.isFinite, (0.001...0.02).contains(value.unicodeChunkIntervalSeconds),
              value.maximumUnicodeDeliverySeconds.isFinite, (0.5...5).contains(value.maximumUnicodeDeliverySeconds),
              (1...32).contains(value.maximumFocusWindowCandidates),
              value.maximumFocusResolutionSeconds.isFinite, (0.05...0.5).contains(value.maximumFocusResolutionSeconds),
              value.minimumFloatingWindowDimension.isFinite, (16...256).contains(value.minimumFloatingWindowDimension),
              value.focusWindowMatchTolerance.isFinite, (0...4).contains(value.focusWindowMatchTolerance),
              (1...1_000_000).contains(value.maximumValueUTF16Length),
              (1...256).contains(value.maximumMenuNodes), (1...6).contains(value.maximumMenuDepth)
        else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}

struct TextDeliveryClipboardReceipt {
    let changeCount: Int
    let identifier: String
}

protocol TextDeliveryClipboard {
    func capture() -> ClipboardSnapshot
    func write(_ text: String, transient: Bool) -> TextDeliveryClipboardReceipt?
    func owns(_ text: String, receipt: TextDeliveryClipboardReceipt) -> Bool
    func restore(_ snapshot: ClipboardSnapshot, changeCount: Int)
}

final class SystemTextDeliveryClipboard: TextDeliveryClipboard {
    private static let deliveryIdentifierType = NSPasteboard.PasteboardType("com.mytype.text-delivery-id")
    let pasteboard: NSPasteboard

    /// Uses a supplied pasteboard so isolated checks never touch the user's clipboard.
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    /// Captures only safe text formats for an eventual verified restoration.
    func capture() -> ClipboardSnapshot { ClipboardSnapshot.capture(from: pasteboard) }

    /// Publishes text and its transient marker together, then verifies the stored text.
    func write(_ text: String, transient: Bool) -> TextDeliveryClipboardReceipt? {
        let item = NSPasteboardItem()
        let identifier = UUID().uuidString
        guard item.setString(text, forType: .string),
              item.setString(identifier, forType: Self.deliveryIdentifierType) else { return nil }
        if transient { PasteboardHistoryPolicy.markTransient(item) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        let receipt = TextDeliveryClipboardReceipt(changeCount: pasteboard.changeCount, identifier: identifier)
        return owns(text, receipt: receipt) ? receipt : nil
    }

    /// Checks both text and generation before sending or restoring clipboard content.
    func owns(_ text: String, receipt: TextDeliveryClipboardReceipt) -> Bool {
        pasteboard.changeCount == receipt.changeCount
            && pasteboard.string(forType: Self.deliveryIdentifierType) == receipt.identifier
            && pasteboard.string(forType: .string) == text
            && pasteboard.changeCount == receipt.changeCount
    }

    /// Restores a snapshot only while the pasteboard generation still belongs to this write.
    func restore(_ snapshot: ClipboardSnapshot, changeCount: Int) {
        snapshot.restore(to: pasteboard, expectedChangeCount: changeCount)
    }
}

final class ClipboardDeliveryTransaction {
    private let clipboard: TextDeliveryClipboard
    private let configuration: TextDeliveryConfiguration
    private let wait: (TimeInterval) -> Void

    /// Supplies the clipboard, delivery bounds, and a replaceable wait for isolated checks.
    init(clipboard: TextDeliveryClipboard = SystemTextDeliveryClipboard(),
         configuration: TextDeliveryConfiguration = .init(),
         wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.clipboard = clipboard
        self.configuration = configuration
        self.wait = wait
    }

    /// Sends text once and restores old content only after the destination confirms insertion.
    ///
    /// Args:
    ///   text: Final dictated text to publish.
    ///   target: Original application and focused input control.
    ///   restoreOriginal: Whether verified delivery should restore the prior clipboard.
    /// Returns:
    ///   An observed result; posting an event alone never counts as inserted.
    func deliver(_ text: String, to target: TextDeliveryTarget, restoreOriginal: Bool) -> TextDeliveryResult {
        let snapshot = restoreOriginal ? clipboard.capture() : nil
        guard let receipt = clipboard.write(text, transient: restoreOriginal) else { return .clipboardWriteFailed }
        let ownsClipboard = { self.clipboard.owns(text, receipt: receipt) }
        let shouldDispatch = {
            guard target.isCurrent(), ownsClipboard() else { return false }
            switch target.observation() {
            case .unchanged, .unavailable: return ownsClipboard()
            case .inserted, .changed, .targetChanged: return false
            }
        }
        wait(configuration.pasteboardSettleSeconds)
        guard shouldDispatch() else {
            DebugFileLogger.log("injection: preflight blocked current=\(target.isCurrent()) observation=\(target.observation()) ownsClipboard=\(ownsClipboard())")
            return ownsClipboard() ? .clipboardOnly : .clipboardChanged
        }

        // The proven system event path must run before AX actions that may report success but do nothing.
        // Fall through only when no action was sent. Unconfirmed dispatch is never a retry signal.
        var route = "systemShortcut"
        var dispatched = target.pasteUsingShortcut(shouldDispatch: shouldDispatch)
        if !dispatched {
            guard shouldDispatch() else { return ownsClipboard() ? .clipboardOnly : .clipboardChanged }
            route = "nativeMenu"
            dispatched = target.pasteUsingMenu(shouldDispatch: shouldDispatch) == .dispatched
        }
        if !dispatched {
            guard shouldDispatch() else { return ownsClipboard() ? .clipboardOnly : .clipboardChanged }
            route = "directAX"
            dispatched = target.insertDirectly(shouldDispatch: shouldDispatch) == .dispatched
        }
        guard dispatched else { return ownsClipboard() ? .clipboardOnly : .clipboardChanged }
        DebugFileLogger.log("injection: dispatched route=\(route)")

        let deadline = ProcessInfo.processInfo.systemUptime + configuration.verificationTimeoutSeconds
        let maximumPolls = Int(ceil(configuration.verificationTimeoutSeconds / configuration.verificationPollIntervalSeconds))
        for attempt in 0...maximumPolls {
            let observation = target.observation()
            switch observation {
            case .inserted:
                if let snapshot, ownsClipboard() { clipboard.restore(snapshot, changeCount: receipt.changeCount) }
                return .inserted
            case .unchanged:
                guard attempt < maximumPolls, ProcessInfo.processInfo.systemUptime < deadline else { break }
                wait(configuration.verificationPollIntervalSeconds)
                continue
            case .unavailable, .changed, .targetChanged:
                DebugFileLogger.log("injection: unconfirmed route=\(route) observation=\(observation)")
                break
            }
            break
        }
        return ownsClipboard() ? .pasteAttempted : .clipboardChanged
    }
}
