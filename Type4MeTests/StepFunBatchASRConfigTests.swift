import XCTest
@testable import Type4Me

final class StepFunBatchASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsToStepPlan() throws {
        let config = try XCTUnwrap(StepFunBatchASRConfig(credentials: [
            "apiKey": "  sk-stepfun-test  ",
        ]))

        XCTAssertEqual(config.apiKey, "sk-stepfun-test")
        XCTAssertEqual(config.accessMode, .stepPlan)
        XCTAssertTrue(config.isValid)
    }

    func testInit_acceptsStandardAccessMode() throws {
        let config = try XCTUnwrap(StepFunBatchASRConfig(credentials: [
            "apiKey": "sk-stepfun-test",
            "accessMode": "standard",
        ]))

        XCTAssertEqual(config.accessMode, .standard)
    }

    func testInit_defaultsUnknownAccessModeToStepPlan() throws {
        let config = try XCTUnwrap(StepFunBatchASRConfig(credentials: [
            "apiKey": "sk-stepfun-test",
            "accessMode": "unknown",
        ]))

        XCTAssertEqual(config.accessMode, .stepPlan)
    }

    func testInit_rejectsMissingOrBlankAPIKey() {
        XCTAssertNil(StepFunBatchASRConfig(credentials: [:]))
        XCTAssertNil(StepFunBatchASRConfig(credentials: ["apiKey": "   "]))
    }

    func testToCredentials_roundTripsAPIKeyAndAccessMode() throws {
        let config = try XCTUnwrap(StepFunBatchASRConfig(credentials: [
            "apiKey": "sk-stepfun-test",
            "accessMode": "standard",
        ]))

        XCTAssertEqual(config.toCredentials(), [
            "apiKey": "sk-stepfun-test",
            "accessMode": "standard",
        ])
    }

    func testCredentialFieldsExposeAccessModePicker() throws {
        let fields = StepFunBatchASRConfig.credentialFields
        XCTAssertEqual(fields.map(\.key), ["apiKey", "accessMode"])
        XCTAssertFalse(try XCTUnwrap(fields.first).isOptional)

        let accessMode = try XCTUnwrap(fields.first { $0.key == "accessMode" })
        XCTAssertEqual(accessMode.defaultValue, "stepPlan")
        XCTAssertEqual(accessMode.options.map(\.value), ["stepPlan", "standard"])
    }

    func testRegistry_exposesBatchStepFunProvider() {
        let entry = ASRProviderRegistry.entry(for: .stepfunBatch)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .stepfunBatch) == StepFunBatchASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .stepfunBatch))
        XCTAssertEqual(ASRProviderRegistry.capabilities(for: .stepfunBatch), .batch())
    }
}
