import Foundation
import XCTest
@testable import Type4Me

final class AgentNewTaskServiceTests: XCTestCase {
    /// Checks that project aggregation merges shared directories and excludes unsuitable roots.
    func testProjectAggregationFiltersDirectoriesAndKeepsRecentTitles() throws {
        let sessions = [
            session("a", path: "/projects/MyType", title: "Earlier", time: 10),
            session("b", path: "/projects/MyType/", title: "Latest", time: 20),
            session("c", path: "/", time: 30),
            session("d", path: "/home/user", time: 40),
            session("e", path: "/managed/task-a", time: 50),
            session("f", path: "relative", time: 60),
            session("g", path: "/missing", time: 70),
            session("h", path: "/projects/Other", time: 15),
        ]
        let projects = AgentNewTaskService.projects(
            from: sessions, text: "新开任务", context: .init(application: nil, sessionID: nil),
            homeDirectory: "/home/user", managedTaskRoot: "/managed", canonicalDirectory: canonical,
            configuration: .init()
        )
        XCTAssertEqual(projects.map(\.name), ["MyType", "Other"])
        XCTAssertEqual(projects.first?.recentTitles, ["Latest", "Earlier"])
        XCTAssertEqual(projects.first?.updatedAt, 20)
    }

    /// Checks exact project names survive a recent-project pool limit without substring false matches.
    func testLiteralProjectNameRetainedBeyondRecentPool() {
        var settings = AgentNewTaskConfiguration()
        settings.maximumProjectPool = 2
        let projects = AgentNewTaskService.projects(
            from: [session("a", path: "/projects/MyType", time: 1),
                   session("b", path: "/projects/Newer", time: 20),
                   session("c", path: "/projects/Newest", time: 30)],
            text: "给 mytype 新开一个 Agent", context: .init(application: nil, sessionID: nil),
            homeDirectory: "/home/user", managedTaskRoot: "/managed", canonicalDirectory: canonical,
            configuration: settings
        )
        XCTAssertEqual(projects.first?.name, "MyType")
        XCTAssertEqual(projects.count, 2)
        XCTAssertFalse(AgentNewTaskService.mentionsProject("MyType", in: "MyTypewriter 新任务"))
    }

    /// Checks exact native identity maps search hits to projects without accepting provider collisions.
    func testCandidatesPrioritizeLiteralCurrentAndSearchEvidence() {
        let sessions = [session("a", path: "/projects/A", time: 1),
                        session("b", path: "/projects/Bravo", time: 2),
                        session("c", path: "/projects/Charlie", time: 3),
                        session("d", path: "/projects/Delta", time: 100)]
        let projects = sessions.map {
            AgentNewTaskProject(id: $0.workspacePath!, name: URL(fileURLWithPath: $0.workspacePath!).lastPathComponent,
                                recentTitles: [$0.title], updatedAt: $0.updatedAt)
        }
        let hits = [AgentsViewSearchHit(sessionID: "codex:d", agent: "claude", snippet: "wrong provider"),
                    AgentsViewSearchHit(sessionID: "codex:b", agent: "codex", snippet: "matching work")]
        let result = AgentNewTaskService.candidates(
            projects: projects, sessions: sessions, hits: hits, text: "Charlie 新开任务", currentProjectID: "/projects/A",
            canonicalDirectory: canonical, configuration: .init()
        )
        XCTAssertEqual(result.map(\.id), ["/projects/Charlie", "/projects/A", "/projects/Bravo", "/projects/Delta"])
    }

    /// Checks finite project choices contain useful evidence without private filesystem or native identity.
    func testPayloadContainsOpaqueChoicesAndNoPaths() throws {
        let projects = [project("/projects/MyType")]
        let data = try AgentNewTaskService.payload(
            "在 MyType 新建 Agent", projects: projects, snippets: ["/projects/MyType": "/private/log.jsonl relevant work"],
            currentProjectID: nil, configuration: .init()
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [String: [String: Any]])
        let criteria = try XCTUnwrap(questions["project"]?["criteria"] as? [String: String])
        XCTAssertEqual(Set(criteria.keys), ["project_0", "independent", "unknown"])
        let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(raw.contains("/projects/MyType"))
        XCTAssertFalse(raw.contains("/private/log.jsonl"))
        XCTAssertTrue(raw.contains("MyType"))
        XCTAssertTrue(raw.contains("user_confirmation_required"))
    }

    /// Checks choice decoding accepts only the finite request options and validates probability mass.
    func testChoiceDecoderRejectsInventedProjectAndMalformedProbabilities() throws {
        let projects = [project("/projects/MyType")]
        let ranking = try AgentNewTaskService.decodeResponse(response(project: "project_0"), projects: projects, configuration: .init())
        XCTAssertEqual(ranking.projectID, "/projects/MyType")
        XCTAssertEqual(ranking.application, .codex)
        XCTAssertThrowsError(try AgentNewTaskService.decodeResponse(response(project: "/made/up"), projects: projects, configuration: .init()))
        XCTAssertThrowsError(try AgentNewTaskService.decodeResponse(response(project: "project_0", probability: 0.5), projects: projects, configuration: .init()))
        let independent = try AgentNewTaskService.decodeResponse(response(project: "independent"), projects: projects, configuration: .init())
        XCTAssertEqual(independent.projectID, AgentNewTaskService.independentProjectID)
    }

    /// Checks model failure keeps a unique literal project suggestion while preserving an explicit missing provider.
    func testFailureKeepsLiteralProjectAndUnavailableExplicitProvider() async throws {
        let service = makeService(sessions: [session("a", path: "/projects/MyType")], installed: [.codex])
        let result = try await service.prepare("用 Claude 给 MyType 新开任务", context: .init(application: .codex, sessionID: nil))
        XCTAssertEqual(result.suggestedProjectID, "/projects/MyType")
        XCTAssertEqual(result.suggestedApplication, .claudeCode)
        XCTAssertEqual(result.installedApplications, [.codex])
        XCTAssertFalse(result.needsProjectChoice)
    }

    /// Checks semantic failure never silently selects the newest project or the user's Home directory.
    func testFailureWithoutLiteralProjectRequiresChoice() async throws {
        let service = makeService(sessions: [session("a", path: "/projects/Latest")])
        let result = try await service.prepare("新开一个研究检索的 Agent", context: .init(application: nil, sessionID: nil))
        XCTAssertNil(result.suggestedProjectID)
        XCTAssertTrue(result.needsProjectChoice)
    }

    /// Checks identical project names do not silently select the more recently modified directory.
    func testDuplicateProjectNamesRemainUnselectedWhenRankingFails() async throws {
        let service = makeService(sessions: [session("a", path: "/projects/MyType", time: 1),
                                            session("b", path: "/alternate/MyType", time: 100)])
        let result = try await service.prepare("MyType 新建一个 Agent", context: .init(application: nil, sessionID: nil))
        XCTAssertNil(result.suggestedProjectID)
        XCTAssertEqual(result.projects.count, 2)
    }

    /// Checks a negated project mention does not override the model's independent-task decision.
    func testIndependentDecisionOverridesNegatedLiteralProject() async throws {
        let reply = try response(project: "independent")
        let service = makeService(sessions: [session("a", path: "/projects/MyType")], rank: { _, _ in reply })
        let result = try await service.prepare("不要放 MyType 项目，开一个独立 Agent 研究旅行", context: .init(application: nil, sessionID: nil))
        XCTAssertEqual(result.suggestedProjectID, AgentNewTaskService.independentProjectID)
        let offline = makeService(sessions: [session("a", path: "/projects/MyType")])
        let fallback = try await offline.prepare("不要放 MyType 项目，开一个独立 Agent 研究旅行", context: .init(application: nil, sessionID: nil))
        XCTAssertNil(fallback.suggestedProjectID)
    }

    /// Checks a valid unknown decision clears a literal fallback instead of silently choosing that project.
    func testUnknownDecisionClearsLiteralFallback() async throws {
        let reply = try response(project: "unknown")
        let service = makeService(sessions: [session("a", path: "/projects/MyType")], rank: { _, _ in reply })
        let result = try await service.prepare("MyType 新建 Agent", context: .init(application: nil, sessionID: nil))
        XCTAssertNil(result.suggestedProjectID)
    }

    /// Checks an unknown current conversation cannot be replaced by model guesses or recency.
    func testUnknownCurrentProjectRequiresChoiceEvenWhenModelSelectsAProject() async throws {
        let reply = try response(project: "project_0")
        let service = makeService(sessions: [session("a", path: "/projects/Latest")], rank: { _, _ in reply })
        let result = try await service.prepare("在这个项目里再开一个 Agent", context: .init(application: .codex, sessionID: nil))
        XCTAssertNil(result.suggestedProjectID)
        XCTAssertTrue(result.needsProjectChoice)
    }

    /// Checks a current-project reference uses the exact native conversation rather than a newer unrelated session.
    func testKnownCurrentProjectIsRetained() async throws {
        let service = makeService(sessions: [session("a", path: "/projects/Current", time: 1),
                                            session("b", path: "/projects/Latest", time: 100)])
        let result = try await service.prepare("在这个项目里再开一个 Agent", context: .init(application: .codex, sessionID: "a"))
        XCTAssertEqual(result.suggestedProjectID, "/projects/Current")
    }

    /// Checks provider aliases do not interpret product-name substrings as an explicit provider request.
    func testCloudflareDoesNotOverrideContextProvider() async throws {
        let service = makeService(sessions: [])
        let result = try await service.prepare("新建 Agent 研究 Cloudflare", context: .init(application: .codex, sessionID: nil))
        XCTAssertEqual(result.suggestedApplication, .codex)
    }

    /// Checks a provider mentioned as research subject does not override the current application.
    func testProviderTopicDoesNotBecomeAnExplicitDestination() async throws {
        let reply = try response(project: "independent", provider: "unspecified")
        let service = makeService(sessions: [session("a", path: "/projects/MyType")], rank: { _, _ in reply })
        let result = try await service.prepare("新开一个 Agent 研究 Codex 的接口", context: .init(application: .claudeCode, sessionID: nil))
        XCTAssertEqual(result.suggestedApplication, .claudeCode)
    }

    /// Checks a command provider is distinct from another provider appearing in the task subject.
    func testProviderCommandWinsOverAnotherProviderTopic() async throws {
        let reply = try response(project: "independent", provider: "claudeCode")
        let service = makeService(sessions: [session("a", path: "/projects/MyType")], rank: { _, _ in reply })
        let result = try await service.prepare("用 Claude 新开一个 Agent 研究 Codex 接口", context: .init(application: .codex, sessionID: nil))
        XCTAssertEqual(result.suggestedApplication, .claudeCode)
        let offline = makeService(sessions: [])
        let fallback = try await offline.prepare("用 Claude 新开一个 Agent 研究 Codex 接口", context: .init(application: .codex, sessionID: nil))
        XCTAssertEqual(fallback.suggestedApplication, .claudeCode)
    }

    /// Checks an independent model suggestion never creates its working directory during preparation.
    func testIndependentSelectionRemainsAReadOnlySuggestion() async throws {
        let reply = try response(project: "independent")
        let service = makeService(sessions: [session("a", path: "/projects/MyType")], rank: { _, _ in reply })
        let result = try await service.prepare("新建 Agent 帮我安排旅行", context: .init(application: nil, sessionID: nil))
        XCTAssertEqual(result.suggestedProjectID, AgentNewTaskService.independentProjectID)
        XCTAssertFalse(result.needsProjectChoice)
        XCTAssertEqual(result.projects.count, 1)
    }

    /// Checks the editable menu keeps the full bounded project pool even though Jev sees fewer choices.
    func testPreparationRetainsProjectsBeyondModelCandidateLimit() async throws {
        var configuration = AgentNewTaskConfiguration()
        configuration.maximumCandidates = 1
        let records = [session("a", path: "/projects/One", time: 1), session("b", path: "/projects/Two", time: 2)]
        let service = AgentNewTaskService(
            configuration: configuration, catalog: { records }, installations: { [.codex] }, preferredApplication: { .codex },
            canonicalDirectory: canonical, homeDirectory: "/home/user", managedTaskRoot: "/managed",
            search: { _, _, _, _ in [] }, rank: { _, _ in throw AgentNewTaskError.invalidResponse }
        )
        let result = try await service.prepare("新开任务", context: .init(application: nil, sessionID: nil))
        XCTAssertEqual(result.projects.count, 2)
    }

    /// Checks slow local search returns to the editable metadata choices within the configured short budget.
    func testSearchDeadlineDoesNotBlockProjectPreparation() async throws {
        var configuration = AgentNewTaskConfiguration()
        configuration.searchTimeoutSeconds = 0.02
        let records = [session("a", path: "/projects/MyType")]
        let service = AgentNewTaskService(
            configuration: configuration, catalog: { records }, installations: { [.codex] }, preferredApplication: { .codex },
            canonicalDirectory: canonical, homeDirectory: "/home/user", managedTaskRoot: "/managed",
            search: { _, _, _, _ in try await Task.sleep(for: .seconds(5)); return [] },
            rank: { _, _ in throw AgentNewTaskError.invalidResponse }
        )
        let start = ContinuousClock.now
        let result = try await service.prepare("新开任务研究旅行", context: .init(application: nil, sessionID: nil))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertNil(result.suggestedProjectID)
    }

    /// Checks the native prompt bound is enforced before reading metadata or contacting a model.
    func testRejectsPromptExceedingNativeUTF16Bound() async {
        let service = makeService(sessions: [])
        do {
            _ = try await service.prepare(String(repeating: "😀", count: 2001), context: .init(application: nil, sessionID: nil))
            XCTFail("Oversized native prompt was accepted")
        } catch {
            XCTAssertEqual(error as? AgentNewTaskError, .invalidInput)
        }
    }

    /// Checks production settings are explicit, valid, and missing bundles do not invent defaults.
    func testPackagedConfigurationAndMissingResource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Type4Me/Resources/AgentNewTaskConfig.json"))
        let config = try JSONDecoder().decode(AgentNewTaskConfiguration.self, from: data)
        try config.validate()
        XCTAssertEqual(config.maximumPromptUTF16, 4000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(config), try encoder.encode(AgentNewTaskConfiguration()))
        XCTAssertNotNil("in this project".range(of: config.currentReferencePattern, options: .regularExpression))
        XCTAssertNotNil("use code x".range(of: config.providerPatterns["codex"]!, options: .regularExpression))
        XCTAssertThrowsError(try AgentNewTaskConfiguration.bundled(in: Bundle(for: NSString.self)))
    }

    /// Creates an isolated resolver with no production credentials, filesystem access, or desktop actions.
    private func makeService(
        sessions: [AgentSessionDescriptor], installed: [AgentDesktopApplication] = [.codex, .claudeCode],
        rank: AgentNewTaskService.RankingProvider? = nil
    ) -> AgentNewTaskService {
        AgentNewTaskService(
            configuration: .init(), catalog: { sessions }, installations: { installed }, preferredApplication: { .codex },
            canonicalDirectory: canonical, homeDirectory: "/home/user", managedTaskRoot: "/managed",
            search: { _, _, _, _ in [] }, rank: rank ?? { _, _ in throw AgentNewTaskError.invalidResponse }
        )
    }

    /// Builds one native metadata fixture without storing history or a transcript location.
    private func session(_ id: String, path: String, title: String = "Work", time: TimeInterval = 1) -> AgentSessionDescriptor {
        .init(sessionID: id, application: .codex, title: title, workspacePath: path,
              updatedAt: time, matchTexts: [], openCapability: .codexDeepLink)
    }

    /// Builds one project choice without requiring an actual directory.
    private func project(_ path: String) -> AgentNewTaskProject {
        .init(id: path, name: URL(fileURLWithPath: path).lastPathComponent, recentTitles: ["Recent work"], updatedAt: 100)
    }

    /// Resolves only fixture directories, treating the missing path as absent.
    private var canonical: AgentNewTaskService.DirectoryResolver {
        { path in path.hasPrefix("/") && path != "/missing" ? URL(fileURLWithPath: path).standardizedFileURL.path : nil }
    }

    /// Encodes finite-choice fixtures including a deliberately invalid winning value when requested.
    private func response(project: String, probability: Double = 1, provider: String = "codex") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": "jev-1.13.0",
            "answers": [
                "project": ["type": "choice", "choice": project, "confidence": probability,
                            "probabilities": ["project_0": project == "project_0" ? probability : 0,
                                              "independent": project == "independent" ? probability : 0,
                                              "unknown": project == "unknown" ? probability : 0]],
                "provider": ["type": "choice", "choice": provider, "confidence": 1,
                             "probabilities": ["codex": provider == "codex" ? 1 : 0,
                                               "claudeCode": provider == "claudeCode" ? 1 : 0,
                                               "unspecified": provider == "unspecified" ? 1 : 0]],
            ],
        ])
    }
}
