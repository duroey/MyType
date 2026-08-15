import XCTest
@testable import Type4Me

final class VolcASRClientTests: XCTestCase {
    func testAuthHeadersUseSingleAPIKey() {
        let headers = VolcProtocol.authHeaders(
            authentication: .apiKey("my-api-key"),
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertEqual(headers["X-Api-Key"], "my-api-key")
        XCTAssertEqual(headers["X-Api-Resource-Id"], VolcanoASRConfig.resourceIdSeedASR)
        XCTAssertEqual(headers["X-Api-Connect-Id"], "connect-123")
    }

    func testAPIKeyHeadersOmitLegacyCredentialHeaders() {
        let headers = VolcProtocol.authHeaders(
            authentication: .apiKey("my-api-key"),
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertNil(headers["X-Api-App-Key"])
        XCTAssertNil(headers["X-Api-Access-Key"])
        XCTAssertEqual(headers.count, 3)
    }

    func testLegacyAuthHeadersUseAppIDAndAccessToken() {
        let headers = VolcProtocol.authHeaders(
            authentication: .legacy(appKey: "my-app-id", accessKey: "my-access-token"),
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertNil(headers["X-Api-Key"])
        XCTAssertEqual(headers["X-Api-App-Key"], "my-app-id")
        XCTAssertEqual(headers["X-Api-Access-Key"], "my-access-token")
        XCTAssertEqual(headers.count, 4)
    }

    func testConfigInfersLegacyAuthForExistingCredentials() throws {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: [
            "appKey": "my-app-id",
            "accessKey": "my-access-token",
            "resourceId": VolcanoASRConfig.resourceIdSeedASR,
        ]))

        XCTAssertEqual(config.authMode, VolcanoASRConfig.authModeLegacy)
        XCTAssertEqual(config.appKey, "my-app-id")
        XCTAssertEqual(config.accessKey, "my-access-token")
        XCTAssertNil(config.apiKey)
    }

    func testExplicitAPIKeyModeWinsWhenBothCredentialSetsExist() throws {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: [
            "authMode": VolcanoASRConfig.authModeAPIKey,
            "apiKey": "my-api-key",
            "appKey": "my-app-id",
            "accessKey": "my-access-token",
        ]))

        XCTAssertEqual(config.authMode, VolcanoASRConfig.authModeAPIKey)
        XCTAssertEqual(config.apiKey, "my-api-key")
        XCTAssertNil(config.appKey)
        XCTAssertNil(config.accessKey)
    }

    func testWebSocketUpgradeProbeMessageIsIgnored() {
        let message = #"Bad Request("error", "cannot upgrade to websocket: websocket: the client is not using the websocket protocol: 'upgrade' token not found in 'Connection' header")"#

        XCTAssertTrue(VolcASRError.isWebSocketUpgradeProbeMessage(message))
    }

    func testNormalVendorErrorIsNotIgnored() {
        XCTAssertFalse(VolcASRError.isWebSocketUpgradeProbeMessage("invalid access key"))
    }
}
