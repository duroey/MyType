import Foundation

/// Hardware identity and timing for the physically verified BOYA Magic button report.
struct BoyaButtonConfiguration: Codable, Equatable, Sendable {
    var vendorID = 12037
    var productID = 59
    var reportID: UInt32 = 6
    var pressedReport: [UInt8] = [6, 2, 0]
    var releasedReport: [UInt8] = [6, 0, 0]
    var duplicateWindowSeconds = 0.2
    var cooldownSeconds = 0.6
    var returnDelaySeconds = 0.15
    var refreshSeconds = 2.0
    var axTimeoutSeconds = 0.1
    var maximumInputReportBytes = 64
    var lockFileName = "local.boya.go-button.lock"
    var text = "Go"
    var returnKeyCode: UInt16 = 36

    enum ConfigurationError: Error { case missingResource, invalidConfiguration }

    /// Loads the packaged configuration, with typed defaults for an unpackaged binary.
    ///
    /// Args:
    ///   bundle: Application containing the fixed hardware profile.
    /// Returns:
    ///   Validated configuration without accessing hardware or preferences.
    /// Throws:
    ///   A missing, malformed, or unsupported profile error.
    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "BoyaButtonConfig", withExtension: "json") else {
            guard bundle.bundleURL.pathExtension != "app" else {
                throw ConfigurationError.missingResource
            }
            let configuration = Self()
            try configuration.validate()
            return configuration
        }
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    /// Rejects unsupported device reports and timing that could merge unrelated presses.
    ///
    /// Throws:
    ///   ConfigurationError.invalidConfiguration when a profile violates its bounds.
    func validate() throws {
        guard vendorID == 12037, productID == 59, reportID == 6,
              pressedReport == [6, 2, 0], releasedReport == [6, 0, 0],
              text == "Go", returnKeyCode == 36, maximumInputReportBytes == 64,
              lockFileName == "local.boya.go-button.lock",
              duplicateWindowSeconds.isFinite, (0.1...0.3).contains(duplicateWindowSeconds),
              cooldownSeconds.isFinite, (0.4...2).contains(cooldownSeconds),
              returnDelaySeconds.isFinite, (0.05...0.3).contains(returnDelaySeconds),
              returnDelaySeconds < cooldownSeconds,
              refreshSeconds.isFinite, (1...10).contains(refreshSeconds),
              axTimeoutSeconds.isFinite, (0.05...0.2).contains(axTimeoutSeconds) else {
            throw ConfigurationError.invalidConfiguration
        }
    }
}

enum BoyaButtonState: String {
    case disabled, waitingForDevice, permissionRequired, occupied
    case ambiguousDevice, unsupportedDevice, ready, suspended, failed
}

enum BoyaButtonFeedback: String {
    case none, chooseInput, returnCancelled, posted, failed
}

struct BoyaButtonEventFilter {
    let configuration: BoyaButtonConfiguration
    private var down = false
    private var lastRisingEdge: Double?

    /// Accepts one rising edge from the report emitted by a physical double-click.
    ///
    /// Args:
    ///   reportID: Report identifier supplied by IOKit.
    ///   bytes: Complete input report, including its identifier.
    ///   uptime: Monotonic receipt time.
    /// Returns:
    ///   True once per press group; releases, repeats, and other reports return false.
    mutating func receive(reportID: UInt32, bytes: [UInt8], uptime: Double) -> Bool {
        guard uptime.isFinite, uptime >= 0, reportID == configuration.reportID else { return false }
        if bytes == configuration.releasedReport {
            down = false
            return false
        }
        guard bytes == configuration.pressedReport, !down else { return false }
        down = true
        let previous = lastRisingEdge
        lastRisingEdge = uptime
        return previous.map { uptime - $0 >= configuration.duplicateWindowSeconds } ?? true
    }

    /// Discards incomplete physical gestures when the device connection changes.
    mutating func reset() {
        down = false
        lastRisingEdge = nil
    }
}

struct BoyaButtonActionGate {
    let cooldownSeconds: Double
    private var activeToken: UUID?
    private var lastStarted: Double?

    /// Reserves a single action, discarding presses while disconnected, busy, or cooling down.
    ///
    /// Args:
    ///   ready: Whether hardware, lifecycle, and permission gates are all satisfied.
    ///   uptime: Monotonic event time.
    /// Returns:
    ///   A token used to reject stale callbacks, or nil without queuing the press.
    mutating func begin(ready: Bool, uptime: Double) -> UUID? {
        guard ready, uptime.isFinite, uptime >= 0, activeToken == nil else { return nil }
        if let lastStarted, uptime - lastStarted < cooldownSeconds { return nil }
        let token = UUID()
        activeToken = token
        lastStarted = uptime
        return token
    }

    /// Checks whether a delayed send still belongs to the currently admitted action.
    func isCurrent(_ token: UUID) -> Bool { activeToken == token }

    /// Finishes only the matching action so an old callback cannot release a newer one.
    mutating func finish(_ token: UUID) {
        if activeToken == token { activeToken = nil }
    }

    /// Invalidates delayed output without replaying missed presses after reconnecting.
    mutating func cancel() { activeToken = nil }
}
