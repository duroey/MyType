import Foundation
import XCTest
@testable import Type4Me

final class BoyaButtonTests: XCTestCase {
    /// Accepts one physical double-click despite the receiver's repeated press/release pulses.
    func testPhysicalDuplicatePulsesProduceOneAction() {
        let configuration = BoyaButtonConfiguration()
        var filter = BoyaButtonEventFilter(configuration: configuration)
        let pulses: [(Double, [UInt8])] = [
            (10, [6, 2, 0]),
            (10.01, [6, 0, 0]),
            (10.05, [6, 2, 0]),
            (10.06, [6, 0, 0]),
            (10.10, [6, 2, 0]),
            (10.11, [6, 0, 0]),
        ]
        let accepted = pulses.map { uptime, bytes in
            filter.receive(reportID: 6, bytes: bytes, uptime: uptime)
        }

        XCTAssertEqual(accepted, [true, false, false, false, false, false])
        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 11))
    }

    /// Requires a matching release before another rising edge can be accepted.
    func testHeldPressAndWrongReleaseCannotCreateAnotherAction() {
        var filter = BoyaButtonEventFilter(configuration: .init())

        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 10))
        XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 11))
        XCTAssertFalse(filter.receive(reportID: 7, bytes: [6, 0, 0], uptime: 12))
        XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 0], uptime: 13))
        XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 14))
        XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 0, 0], uptime: 15))
        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 16))
    }

    /// Ignores releases, unrelated report identifiers, and malformed report contents.
    func testUnsupportedReportsDoNotArmOrTriggerTheFilter() {
        let invalidReports: [(UInt32, [UInt8])] = [
            (6, [6, 0, 0]),
            (7, [6, 2, 0]),
            (6, []),
            (6, [6, 2]),
            (6, [6, 2, 0, 0]),
            (6, [6, 1, 0]),
            (6, [6, 2, 1]),
            (6, [7, 2, 0]),
        ]
        var filter = BoyaButtonEventFilter(configuration: .init())

        for (reportID, bytes) in invalidReports {
            XCTAssertFalse(filter.receive(reportID: reportID, bytes: bytes, uptime: 10))
        }
        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 10))
    }

    /// Invalid timestamps cannot change the filter's current physical press state.
    func testInvalidTimesDoNotConsumeOrReleasePresses() {
        var filter = BoyaButtonEventFilter(configuration: .init())
        let invalidTimes: [Double] = [-1, .nan, .infinity, -.infinity]

        for uptime in invalidTimes {
            XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: uptime))
        }
        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 10))
        for uptime in invalidTimes {
            XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 0, 0], uptime: uptime))
        }
        XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 20))
    }

    /// Disconnecting clears both a held press and the previous connection's duplicate window.
    func testDisconnectResetAcceptsFirstPressFromNewConnection() {
        var filter = BoyaButtonEventFilter(configuration: .init())

        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 10))
        filter.reset()
        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 10.01))
        XCTAssertFalse(filter.receive(reportID: 6, bytes: [6, 0, 0], uptime: 10.02))
        filter.reset()
        XCTAssertTrue(filter.receive(reportID: 6, bytes: [6, 2, 0], uptime: 10.03))
    }

    /// A disconnected, unready, or invalid-time press cannot reserve a future action.
    ///
    /// Throws:
    ///   An XCTest failure if the first ready action does not receive a token.
    func testGateRejectsUnreadyAndInvalidTimesWithoutConsumingReadiness() throws {
        var gate = BoyaButtonActionGate(cooldownSeconds: 0.6)

        XCTAssertNil(gate.begin(ready: false, uptime: 10))
        for uptime in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertNil(gate.begin(ready: true, uptime: uptime))
        }
        let token = try XCTUnwrap(gate.begin(ready: true, uptime: 10))
        XCTAssertTrue(gate.isCurrent(token))
    }

    /// An in-flight action drops further presses even when the cooldown has elapsed.
    ///
    /// Throws:
    ///   An XCTest failure if the expected action cannot be reserved.
    func testGateRejectsBusyPressesWithoutQueuingThem() throws {
        var gate = BoyaButtonActionGate(cooldownSeconds: 0.6)
        let first = try XCTUnwrap(gate.begin(ready: true, uptime: 0))

        XCTAssertNil(gate.begin(ready: true, uptime: 10))
        XCTAssertTrue(gate.isCurrent(first))
        gate.finish(first)
        XCTAssertFalse(gate.isCurrent(first))
        let next = try XCTUnwrap(gate.begin(ready: true, uptime: 10))
        XCTAssertNotEqual(first, next)
    }

    /// Finishing an action retains cooldown, while the configured boundary allows a new press.
    ///
    /// Throws:
    ///   An XCTest failure if an allowed action cannot be reserved.
    func testGateCooldownRemainsAfterCompletion() throws {
        let cooldown = BoyaButtonConfiguration().cooldownSeconds
        var gate = BoyaButtonActionGate(cooldownSeconds: cooldown)
        let first = try XCTUnwrap(gate.begin(ready: true, uptime: 0))
        gate.finish(first)

        XCTAssertNil(gate.begin(ready: true, uptime: cooldown / 2))
        XCTAssertNil(gate.begin(ready: false, uptime: cooldown))
        XCTAssertNotNil(gate.begin(ready: true, uptime: cooldown))
    }

    /// Disconnect cancellation invalidates delayed output without bypassing cooldown.
    ///
    /// Throws:
    ///   An XCTest failure if the initial action cannot be reserved.
    func testGateCancellationInvalidatesTokenAndRetainsCooldown() throws {
        var gate = BoyaButtonActionGate(cooldownSeconds: 0.6)
        let first = try XCTUnwrap(gate.begin(ready: true, uptime: 0))

        gate.cancel()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertNil(gate.begin(ready: true, uptime: 0.1))
        XCTAssertNotNil(gate.begin(ready: true, uptime: 1))
    }

    /// An old completion cannot unlock a newer action admitted after reconnecting.
    ///
    /// Throws:
    ///   An XCTest failure if either connection's action cannot be reserved.
    func testOldCompletionCannotUnlockNewAction() throws {
        var gate = BoyaButtonActionGate(cooldownSeconds: 0.6)
        let oldToken = try XCTUnwrap(gate.begin(ready: true, uptime: 0))
        gate.cancel()
        let newToken = try XCTUnwrap(gate.begin(ready: true, uptime: 1))

        XCTAssertFalse(gate.isCurrent(oldToken))
        XCTAssertTrue(gate.isCurrent(newToken))
        gate.finish(oldToken)
        gate.finish(UUID())
        XCTAssertTrue(gate.isCurrent(newToken))
        XCTAssertNil(gate.begin(ready: true, uptime: 10))
        gate.finish(newToken)
        XCTAssertNotNil(gate.begin(ready: true, uptime: 10))
    }

    /// The packaged profile and typed defaults describe the same verified device and bounds.
    ///
    /// Throws:
    ///   A file-read, JSON-decoding, or validation error when the source fixture is invalid.
    func testPackagedConfigurationMatchesTypedDefaults() throws {
        let configuration = try JSONDecoder().decode(
            BoyaButtonConfiguration.self, from: Data(contentsOf: configurationURL())
        )

        try configuration.validate()
        XCTAssertEqual(configuration, BoyaButtonConfiguration())
    }

    /// Missing fields fail decoding instead of silently enabling an incomplete hardware profile.
    ///
    /// Throws:
    ///   A file-read or JSON-serialization error when preparing the incomplete fixture.
    func testMissingConfigurationFieldIsRejected() throws {
        let original = try Data(contentsOf: configurationURL())
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        fields.removeValue(forKey: "reportID")
        let incomplete = try JSONSerialization.data(withJSONObject: fields)

        XCTAssertThrowsError(try JSONDecoder().decode(BoyaButtonConfiguration.self, from: incomplete))
    }

    /// Configuration changes cannot redirect output or broaden the supported hardware profile.
    func testUnsupportedIdentityReportsAndOutputAreRejected() {
        let mutations: [(String, (inout BoyaButtonConfiguration) -> Void)] = [
            ("vendor", { $0.vendorID = 1 }),
            ("product", { $0.productID = 1 }),
            ("report identifier", { $0.reportID = 7 }),
            ("press bytes", { $0.pressedReport = [6, 1, 0] }),
            ("release bytes", { $0.releasedReport = [6, 0] }),
            ("report capacity", { $0.maximumInputReportBytes = 65 }),
            ("lock identity", { $0.lockFileName = "another.lock" }),
            ("output text", { $0.text = "Go\n" }),
            ("Return key", { $0.returnKeyCode = 0 }),
        ]

        assertInvalidConfigurations(mutations)
    }

    /// Invalid timing cannot create unbounded polling, immediate retries, or unsafe event delays.
    func testInvalidTimingIsRejected() {
        let mutations: [(String, (inout BoyaButtonConfiguration) -> Void)] = [
            ("duplicate window too short", { $0.duplicateWindowSeconds = 0.09 }),
            ("duplicate window too long", { $0.duplicateWindowSeconds = 0.31 }),
            ("duplicate window not finite", { $0.duplicateWindowSeconds = .nan }),
            ("cooldown too short", { $0.cooldownSeconds = 0.39 }),
            ("cooldown too long", { $0.cooldownSeconds = 2.01 }),
            ("cooldown not finite", { $0.cooldownSeconds = .infinity }),
            ("Return delay too short", { $0.returnDelaySeconds = 0.04 }),
            ("Return delay too long", { $0.returnDelaySeconds = 0.31 }),
            ("Return delay not finite", { $0.returnDelaySeconds = .nan }),
            ("refresh too frequent", { $0.refreshSeconds = 0.99 }),
            ("refresh too slow", { $0.refreshSeconds = 10.01 }),
            ("refresh not finite", { $0.refreshSeconds = .infinity }),
            ("AX timeout too short", { $0.axTimeoutSeconds = 0.04 }),
            ("AX timeout too long", { $0.axTimeoutSeconds = 0.21 }),
            ("AX timeout not finite", { $0.axTimeoutSeconds = .nan }),
        ]

        assertInvalidConfigurations(mutations)
    }

    /// Resolves the repository's configuration fixture without opening hardware or app preferences.
    ///
    /// Returns:
    ///   The BOYA JSON source resource beside the application's other bundled configuration files.
    private func configurationURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/BoyaButtonConfig.json")
    }

    /// Checks that each isolated mutation is rejected by the configuration's validation boundary.
    ///
    /// Args:
    ///   mutations: Descriptions and changes applied independently to valid typed defaults.
    ///   file: Caller source location used for assertion diagnostics.
    ///   line: Caller line number used for assertion diagnostics.
    private func assertInvalidConfigurations(
        _ mutations: [(String, (inout BoyaButtonConfiguration) -> Void)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (description, mutate) in mutations {
            var configuration = BoyaButtonConfiguration()
            mutate(&configuration)
            XCTAssertThrowsError(try configuration.validate(), description, file: file, line: line)
        }
    }
}
