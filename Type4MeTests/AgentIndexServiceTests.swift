import Foundation
import XCTest
@testable import Type4Me

final class AgentIndexServiceTests: XCTestCase {
    /// Verifies the installed scope and transport remain bounded to the tested local protocol.
    ///
    /// Raises:
    ///   Error: Valid defaults were rejected.
    func testConfigurationPinsLoopbackVersionsAndThirtyDayScope() throws {
        let baseline = AgentIndexService.Configuration()
        XCTAssertEqual(try baseline.validatedEndpoint().host, "127.0.0.1")
        XCTAssertEqual(baseline.expectedIndexScope, "dialogue-date-v1|days=30|from=|to=|tz=UTC")
        for endpoint in ["http://localhost:18742", "http://127.0.0.1:18743", "https://example.com", "http://127.0.0.1:18742/resync"] {
            var changed = baseline
            changed.endpoint = endpoint
            XCTAssertThrowsError(try changed.validatedEndpoint())
        }
        var changed = baseline
        changed.expectedIndexScope = "all"
        XCTAssertThrowsError(try changed.validatedEndpoint())
        changed = baseline
        changed.expectedAPIVersion += 1
        XCTAssertThrowsError(try changed.validatedEndpoint())
    }

    /// Verifies broken timer limits and an expanded restart budget cannot silently become unbounded.
    func testConfigurationRejectsInvalidWorkBounds() {
        var changed = AgentIndexService.Configuration()
        changed.restartDelaysSeconds = [1, 2, 3, 4]
        XCTAssertThrowsError(try changed.validatedEndpoint())
        changed = .init()
        changed.pollIntervalSeconds = 0
        XCTAssertThrowsError(try changed.validatedEndpoint())
        changed = .init()
        changed.resourceTimeoutSeconds = .infinity
        XCTAssertThrowsError(try changed.validatedEndpoint())
        changed = .init()
        changed.maximumRuntimeRecordBytes = 0
        XCTAssertThrowsError(try changed.validatedEndpoint())
    }

    /// Verifies repeated crashes exhaust a fixed budget instead of resetting after each retry.
    func testRestartBudgetStopsAfterConfiguredAttempts() {
        var budget = AgentIndexService.RestartBudget()
        let delays = [2.0, 8.0, 30.0]
        XCTAssertEqual(budget.nextDelay(delays), 2)
        XCTAssertEqual(budget.nextDelay(delays), 8)
        XCTAssertEqual(budget.nextDelay(delays), 30)
        XCTAssertNil(budget.nextDelay(delays))
        XCTAssertNil(budget.nextDelay(delays))
        XCTAssertEqual(budget.restarts, 3)
    }

    /// Verifies mismatched APIs, archive versions and read-only daemons cannot receive managed writes.
    ///
    /// Raises:
    ///   Error: A synthetic version response could not be decoded.
    func testVersionCompatibilityRequiresBothPinsAndWritableMode() throws {
        let settings = AgentIndexService.Configuration()
        for (json, expected) in [
            (#"{"api_version":10,"data_version":128}"#, true),
            (#"{"api_version":9,"data_version":128}"#, false),
            (#"{"api_version":10,"data_version":129}"#, false),
            (#"{"api_version":10,"data_version":128,"read_only":true}"#, false),
        ] {
            let value = try decode(AgentIndexVersion.self, json)
            XCTAssertEqual(value.compatible(with: settings), expected)
        }
    }

    /// Verifies orphan recovery needs the exact executable and kernel birth time in addition to PID.
    ///
    /// Raises:
    ///   Error: A synthetic runtime response could not be decoded.
    func testRuntimeIdentityRejectsPIDReuseAndUnrelatedExecutable() throws {
        let runtime = try decode(AgentIndexRuntime.self, #"{"pid":12345,"network":"tcp","address":"127.0.0.1:18742","service":"agentsview","metadata":{"no_sync":"false","read_only":"false","api_version":"10","data_version":"128","create_time":"1000050"}}"#)
        let ping = try decode(AgentIndexPing.self, #"{"ok":true,"healthy":true,"service":"agentsview","pid":12345}"#)
        let helper = URL(fileURLWithPath: "/synthetic-fixture/App.app/Contents/Helpers/agentsview")
        let valid = AgentIndexProcessIdentity(pid: 12345, startMilliseconds: 1_000_050, executable: helper.path)
        XCTAssertTrue(AgentIndexService.matchesRuntime(runtime, ping: ping, identity: valid, helper: helper, configuration: .init()))
        let reused = AgentIndexProcessIdentity(pid: 12345, startMilliseconds: 2_000_050, executable: helper.path)
        XCTAssertFalse(AgentIndexService.matchesRuntime(runtime, ping: ping, identity: reused, helper: helper, configuration: .init()))
        let unrelated = AgentIndexProcessIdentity(pid: 12345, startMilliseconds: 1_000_050, executable: "/synthetic-fixture/unrelated")
        XCTAssertFalse(AgentIndexService.matchesRuntime(runtime, ping: ping, identity: unrelated, helper: helper, configuration: .init()))
    }

    /// Verifies a deliberately frozen daemon remains outside this application's managed lifecycle.
    ///
    /// Raises:
    ///   Error: A synthetic runtime response could not be decoded.
    func testRuntimeIdentityRejectsNoSyncDaemon() throws {
        let runtime = try decode(AgentIndexRuntime.self, #"{"pid":12345,"network":"tcp","address":"127.0.0.1:18742","service":"agentsview","metadata":{"no_sync":"true","read_only":"false","api_version":"10","data_version":"128","create_time":"1000050"}}"#)
        let ping = try decode(AgentIndexPing.self, #"{"ok":true,"healthy":true,"service":"agentsview","pid":12345}"#)
        let helper = URL(fileURLWithPath: "/synthetic-fixture/App.app/Contents/Helpers/agentsview")
        let live = AgentIndexProcessIdentity(pid: 12345, startMilliseconds: 1_000_050, executable: helper.path)
        XCTAssertFalse(AgentIndexService.matchesRuntime(runtime, ping: ping, identity: live, helper: helper, configuration: .init()))
    }

    /// Verifies an idle embedding worker alone cannot make an unobserved archive appear complete.
    ///
    /// Raises:
    ///   Error: A synthetic status response could not be decoded.
    func testIdleWorkerWithoutSyncOrCoverageRemainsUnconfirmed() throws {
        let sync = try decode(AgentIndexSyncStatus.self, #"{"last_sync":"","stats":{"failed":0}}"#)
        let embedding = try decode(AgentIndexEmbeddingStatus.self, #"{"running":false,"done":0,"total":0}"#)
        let value = AgentIndexService.summarize(sync: sync, embeddings: embedding, coverage: nil,
                                               checkedAt: Date(), backendUnavailable: false, syncRequested: false)
        XCTAssertEqual(value.phase, .partialFailure)
        XCTAssertTrue(value.searchMayBeIncomplete)
        XCTAssertNil(value.lastSyncAt)
    }

    /// Verifies sync and vector work remain separately observable with missing coverage retained.
    ///
    /// Raises:
    ///   Error: A synthetic status response could not be decoded.
    func testActiveSyncAndEmbeddingHaveDistinctStates() throws {
        let progress = try decode(AgentIndexSyncStatus.self, #"{"last_sync":"2026-10-12T01:02:03Z","stats":{"failed":0},"progress":{"phase":"syncing"}}"#)
        let idle = try decode(AgentIndexSyncStatus.self, #"{"last_sync":"2026-10-12T01:02:03Z","stats":{"failed":0}}"#)
        let embedding = try decode(AgentIndexEmbeddingStatus.self, #"{"running":true,"done":7,"total":20}"#)
        let coverage = AgentIndexGeneration(state: "active", embedded: 100, missing: 20)
        let syncing = AgentIndexService.summarize(sync: progress, embeddings: embedding, coverage: coverage,
                                                 checkedAt: Date(), backendUnavailable: false, syncRequested: false)
        let building = AgentIndexService.summarize(sync: idle, embeddings: embedding, coverage: coverage,
                                                  checkedAt: Date(), backendUnavailable: false, syncRequested: false)
        XCTAssertEqual(syncing.phase, .syncing)
        XCTAssertEqual(building.phase, .embedding)
        XCTAssertEqual(building.processedChunks, 7)
        XCTAssertEqual(building.missingDocuments, 20)
        XCTAssertTrue(building.searchMayBeIncomplete)
    }

    /// Verifies aborts, parser failures and vector errors stay visible even when the worker is idle.
    ///
    /// Raises:
    ///   Error: A synthetic status response could not be decoded.
    func testPartialFailuresAreNotPresentedAsCompleted() throws {
        for stats in [#"{"failed":1}"#, #"{"failed":0,"aborted":true}"#, #"{"failed":0,"warnings":["fixture warning"]}"#] {
            let sync = try decode(AgentIndexSyncStatus.self, "{\"last_sync\":\"2026-10-12T01:02:03Z\",\"stats\":" + stats + "}")
            let embedding = try decode(AgentIndexEmbeddingStatus.self, #"{"running":false,"done":1,"total":1}"#)
            let value = AgentIndexService.summarize(sync: sync, embeddings: embedding,
                                                   coverage: .init(state: "active", embedded: 1, missing: 0),
                                                   checkedAt: Date(), backendUnavailable: false, syncRequested: false)
            XCTAssertEqual(value.phase, .partialFailure)
            XCTAssertTrue(value.searchMayBeIncomplete)
        }
    }

    /// Verifies available coverage is described as checked and changes language with its timestamps.
    ///
    /// Raises:
    ///   Error: A synthetic status response could not be decoded.
    func testCheckedStatusIncludesLocalizedSyncTime() throws {
        let sync = try decode(AgentIndexSyncStatus.self, #"{"last_sync":"2026-10-12T01:02:03.123Z","stats":{"failed":0}}"#)
        let embedding = try decode(AgentIndexEmbeddingStatus.self, #"{"running":false,"done":1,"total":1}"#)
        let value = AgentIndexService.summarize(sync: sync, embeddings: embedding,
                                               coverage: .init(state: "active", embedded: 1, missing: 0),
                                               checkedAt: Date(), backendUnavailable: false, syncRequested: false)
        XCTAssertEqual(value.phase, .checked)
        XCTAssertNotNil(value.lastSyncAt)
        XCTAssertFalse(value.searchMayBeIncomplete)
        XCTAssertTrue(value.summary(language: .zh).contains("最近同步"))
        XCTAssertTrue(value.summary(language: .en).contains("Last sync"))
        XCTAssertFalse(value.summary(language: .en).contains("complete"))
    }

    /// Verifies stamped documents rejected by the encoder remain visible as incomplete coverage.
    ///
    /// Raises:
    ///   Error: Synthetic metadata could not be decoded.
    func testSkippedPassagesKeepZeroBacklogCoverageUnconfirmed() throws {
        let sync = try decode(AgentIndexSyncStatus.self, #"{"last_sync":"2026-10-12T01:02:03Z","stats":{"failed":0}}"#)
        let embedding = try decode(AgentIndexEmbeddingStatus.self, #"{"running":false,"done":3,"total":3,"last_result":{"Fill":{"Documents":2,"Skipped":1}}}"#)
        XCTAssertEqual(embedding.skippedDocuments, 1)
        let value = AgentIndexService.summarize(sync: sync, embeddings: embedding,
                                               coverage: .init(state: "active", embedded: 3, missing: 0),
                                               checkedAt: Date(), backendUnavailable: false, syncRequested: false)
        XCTAssertEqual(value.phase, .partialFailure)
        XCTAssertEqual(value.observedSkippedDocuments, 1)
        XCTAssertTrue(value.searchMayBeIncomplete)
        XCTAssertTrue(value.summary(language: .zh).contains("曾跳过"))
        XCTAssertTrue(value.summary(language: .en).contains("previously skipped"))
    }

    /// Verifies later empty builds or helper restarts cannot erase an already observed skipped passage.
    ///
    /// Raises:
    ///   Error: Synthetic metadata could not be decoded.
    func testObservedSkippedPassagesSurviveLaterEmptyResults() throws {
        let sync = try decode(AgentIndexSyncStatus.self, #"{"last_sync":"2026-10-12T01:02:03Z","stats":{"failed":0}}"#)
        var observedSkippedDocuments = 0
        for result in [#","last_result":{"Fill":{"Skipped":2}}"#,
                       #","last_result":{"Fill":{"Skipped":2}}"#,
                       #","last_result":{"Fill":{"Skipped":0}}"#,
                       ""] {
            let embedding = try decode(AgentIndexEmbeddingStatus.self,
                #"{"running":false,"done":0,"total":0"# + result + "}")
            let value = AgentIndexService.summarize(sync: sync, embeddings: embedding,
                                                   coverage: .init(state: "active", embedded: 3, missing: 0),
                                                   checkedAt: Date(), backendUnavailable: false, syncRequested: false,
                                                   previouslyObservedSkippedDocuments: observedSkippedDocuments)
            observedSkippedDocuments = value.observedSkippedDocuments
            XCTAssertEqual(value.phase, .partialFailure)
            XCTAssertEqual(observedSkippedDocuments, 2)
            XCTAssertTrue(value.searchMayBeIncomplete)
        }
    }

    /// Verifies malformed skipped counts fail closed instead of appearing as successful coverage.
    func testEmbeddingStatusRejectsNegativeSkippedCount() {
        XCTAssertThrowsError(try decode(AgentIndexEmbeddingStatus.self,
            #"{"running":false,"done":1,"total":1,"last_result":{"Fill":{"Skipped":-1}}}"#))
    }

    /// Decodes an isolated status fixture without contacting the helper or opening user files.
    ///
    /// Args:
    ///   type: Expected metadata type.
    ///   json: Synthetic API JSON.
    ///
    /// Returns:
    ///   The decoded metadata fixture.
    ///
    /// Raises:
    ///   Error: The fixture violates the response schema.
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
