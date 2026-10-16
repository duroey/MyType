import Foundation
import XCTest
@testable import Type4Me

final class AgentNewTaskLocalProbeTests: XCTestCase {
    /// Reads actual native metadata only when explicitly enabled, without invoking Jev or opening apps.
    ///
    /// Raises:
    ///   Error: The opt-in local catalog probe cannot read project metadata.
    func testActualProjectCatalogWithoutOpeningOrAllocating() async throws {
        guard ProcessInfo.processInfo.environment["MYTYPE_PROBE_NEW_TASK_CATALOG"] == "1" else {
            throw XCTSkip("Set MYTYPE_PROBE_NEW_TASK_CATALOG=1 for the read-only native catalog probe.")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath().path
        let service = AgentNewTaskService(configuration: .init(),
            search: { _, _, _, _ in [] }, rank: { _, _ in throw AgentIntentClassifierError.unavailable })
        let result = try await service.prepare("给 MyType 新开一个 Agent", context: .init(application: .codex, sessionID: nil))
        XCTAssertTrue(result.projects.contains { $0.id == project })
        XCTAssertTrue(result.installedApplications.contains(.codex))
        XCTAssertTrue(result.installedApplications.contains(.claudeCode))
        let matches = result.projects.filter { $0.name.caseInsensitiveCompare("MyType") == .orderedSame }
        if matches.count == 1 { XCTAssertEqual(result.suggestedProjectID, project) }
        else { XCTAssertNil(result.suggestedProjectID) }
        let current = try await service.prepare("在这个项目里新开一个 Agent", context: .init(application: .codex, sessionID: nil))
        XCTAssertNil(current.suggestedProjectID)
        XCTAssertTrue(current.needsProjectChoice)
        print("Native project probe: \(result.projects.count) projects, \(result.installedApplications.count) installed apps; explicit MyType/current-unknown checks completed.")
    }
}
