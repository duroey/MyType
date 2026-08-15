import XCTest
@testable import Type4Me

final class HistoryStoreTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testInsertAndFetchAll() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 3.5,
            rawText: "测试文本", processingMode: nil, processedText: nil,
            finalText: "测试文本", status: "completed", characterCount: 4, asrProvider: nil
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.rawText, "测试文本")
        XCTAssertEqual(all.first?.durationSeconds ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(all.first?.characterCount, 4)
    }

    func testInsertWithProcessedText() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 2.0,
            rawText: "原始文本", processingMode: "润色",
            processedText: "润色后的文本", finalText: "润色后的文本", status: "completed",
            characterCount: 6, asrProvider: nil
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.processingMode, "润色")
        XCTAssertEqual(all.first?.processedText, "润色后的文本")
        XCTAssertEqual(all.first?.characterCount, 6)
    }

    func testDelete() async {
        let id = UUID().uuidString
        let record = HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1.0,
            rawText: "to delete", processingMode: nil, processedText: nil,
            finalText: "to delete", status: "completed", characterCount: 9, asrProvider: nil
        )
        await store.insert(record)
        await store.delete(id: id)
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchAllOrderedByDate() async {
        let old = HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3, asrProvider: nil
        )
        let recent = HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "recent", processingMode: nil, processedText: nil,
            finalText: "recent", status: "completed", characterCount: 6, asrProvider: nil
        )
        await store.insert(old)
        await store.insert(recent)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.rawText, "recent")
        XCTAssertEqual(all.last?.rawText, "old")
    }

    func testDeleteAll() async {
        for i in 0..<3 {
            await store.insert(HistoryRecord(
                id: "\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "text\(i)", processingMode: nil, processedText: nil,
                finalText: "text\(i)", status: "completed", characterCount: 5 + i, asrProvider: nil
            ))
        }
        await store.deleteAll()
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteBatchEmptyDoesNothing() async {
        let id = "only-one"
        await store.insert(HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1,
            rawText: "x", processingMode: nil, processedText: nil,
            finalText: "x", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.delete(ids: [])
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, id)
    }

    func testDeleteBatch() async {
        for i in 0..<5 {
            await store.insert(HistoryRecord(
                id: "batch-\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "t\(i)", processingMode: nil, processedText: nil,
                finalText: "t\(i)", status: "completed", characterCount: 2, asrProvider: nil
            ))
        }
        await store.delete(ids: ["batch-0", "batch-2", "batch-4"])
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 2)
        let ids = Set(all.map(\.id))
        XCTAssertEqual(ids, Set(["batch-1", "batch-3"]))
    }

    func testDeleteBatchPostsSingleNotification() async {
        await store.insert(HistoryRecord(
            id: "a", createdAt: Date(), durationSeconds: 1,
            rawText: "a", processingMode: nil, processedText: nil,
            finalText: "a", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "b", createdAt: Date(), durationSeconds: 1,
            rawText: "b", processingMode: nil, processedText: nil,
            finalText: "b", status: "completed", characterCount: 1, asrProvider: nil
        ))

        let batchNote = expectation(forNotification: .historyStoreDidChange, object: nil)
        await store.delete(ids: ["a", "b"])
        await fulfillment(of: [batchNote], timeout: 1.0)

        let remaining = await store.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInsertPostsHistoryDidChangeNotification() async {
        let notification = expectation(forNotification: .historyStoreDidChange, object: nil)
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.2,
            rawText: "notify", processingMode: "智能模式", processedText: "notify",
            finalText: "notify", status: "completed", characterCount: 6, asrProvider: nil
        )

        await store.insert(record)

        await fulfillment(of: [notification], timeout: 1.0)
    }

    func testDatabaseConnectionClosesWhenStoreIsReleased() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-fd-\(UUID().uuidString).db")
            .path
        var scopedStore: HistoryStore? = HistoryStore(path: path)
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.0,
            rawText: "fd", processingMode: nil, processedText: nil,
            finalText: "fd", status: "completed", characterCount: 2, asrProvider: nil
        )

        await scopedStore?.insert(record)
        XCTAssertGreaterThan(try openFileDescriptorCount(containing: path), 0)

        scopedStore = nil

        XCTAssertEqual(try openFileDescriptorCount(containing: path), 0)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Counts current-process open file descriptors that reference a path.
    ///
    /// Args:
    ///   path: File path to match in `lsof` output.
    ///
    /// Returns:
    ///   The number of open file descriptors containing `path`.
    private func openFileDescriptorCount(containing path: String) throws -> Int {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", "\(ProcessInfo.processInfo.processIdentifier)"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter { $0.contains(path) }.count
    }

    func testUsageBreakdownGroupsByProviderAndPeriods() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records: [HistoryRecord] = [
            HistoryRecord(
                id: "soniox-now", createdAt: now.addingTimeInterval(-60), durationSeconds: 30,
                rawText: "a", processingMode: nil, processedText: nil,
                finalText: "a", status: "completed", characterCount: 1, asrProvider: "Soniox",
                asrModel: "Soniox · stt-rt-v5"
            ),
            HistoryRecord(
                id: "soniox-week", createdAt: now.addingTimeInterval(-3 * 24 * 60 * 60), durationSeconds: 90,
                rawText: "b", processingMode: nil, processedText: nil,
                finalText: "b", status: "completed", characterCount: 1, asrProvider: "Soniox",
                asrModel: "Soniox · stt-rt-v5"
            ),
            HistoryRecord(
                id: "openai-month", createdAt: now.addingTimeInterval(-10 * 24 * 60 * 60), durationSeconds: 120,
                rawText: "c", processingMode: nil, processedText: nil,
                finalText: "c", status: "completed", characterCount: 1, asrProvider: "OpenAI"
            ),
            HistoryRecord(
                id: "old", createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60), durationSeconds: 300,
                rawText: "d", processingMode: nil, processedText: nil,
                finalText: "d", status: "completed", characterCount: 1, asrProvider: "Old"
            ),
            HistoryRecord(
                id: "elevenlabs-scribe", createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60), durationSeconds: 45,
                rawText: "e", processingMode: nil, processedText: nil,
                finalText: "e", status: "completed", characterCount: 1, asrProvider: "ElevenLabs",
                asrModel: "ElevenLabs · scribe_v2_realtime"
            ),
            HistoryRecord(
                id: "elevenlabs-default", createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60), durationSeconds: 75,
                rawText: "f", processingMode: nil, processedText: nil,
                finalText: "f", status: "completed", characterCount: 1, asrProvider: "ElevenLabs",
                asrModel: "ElevenLabs"
            ),
            HistoryRecord(
                id: "unknown", createdAt: now.addingTimeInterval(-60), durationSeconds: 60,
                rawText: "g", processingMode: nil, processedText: nil,
                finalText: "g", status: "completed", characterCount: 1, asrProvider: nil
            )
        ]

        for record in records {
            await store.insert(record)
        }

        let rows = await store.getUsageBreakdown(now: now)
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.modelName, $0) })

        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.lastDayDuration ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last7DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.lastDayDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last7DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.last30DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.allTimeDuration ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(rows.filter { $0.modelName == "ElevenLabs" }.count, 1)
        XCTAssertEqual(byModel["ElevenLabs"]?.recordCount, 2)
        XCTAssertEqual(byModel["ElevenLabs"]?.last30DaysDuration ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(byModel["ElevenLabs"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(rows.last?.modelName, L("未知", "Unknown"))
        XCTAssertEqual(rows.dropLast().map(\.allTimeDuration), rows.dropLast().map(\.allTimeDuration).sorted(by: >))
    }
}
