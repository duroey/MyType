import Foundation
import XCTest
@testable import Type4Me

@MainActor
final class AgentNewTaskViewModelTests: XCTestCase {
    private let context = AgentNewTaskContext(application: .codex, sessionID: nil)

    /// Builds metadata-only suggestions without looking at any installed application.
    private func preparation(project: String = "independent", application: AgentDesktopApplication = .codex) -> AgentNewTaskPreparation {
        AgentNewTaskPreparation(projects: [], suggestedProjectID: project, suggestedApplication: application,
                               installedApplications: [.codex], needsProjectChoice: false)
    }

    /// Verifies suggestions have no filesystem/launch side effects and confirmation opens only once.
    func testPreparationDoesNotOpenAndConfirmationPreservesPrompt() async {
        let calls = NewTaskCallRecorder()
        let ready = preparation()
        let model = AgentNewTaskViewModel(prepare: { _, _ in ready }, workspace: { project, id in
            await calls.workspace(project, id: id)
            return .project(URL(fileURLWithPath: "/fixture/task"))
        }, open: { application, directory, prompt in await calls.open(application, directory: directory, prompt: prompt) })
        XCTAssertTrue(model.begin("新开一个 Agent\n研究 A+B & C"))
        await model.load(context: context)
        let before = await calls.snapshot()
        XCTAssertEqual(before.workspaces.count, 0)
        XCTAssertEqual(before.prompts.count, 0)
        XCTAssertTrue(model.canOpen)
        let opened = await model.openConfirmedDraft()
        let repeated = await model.openConfirmedDraft()
        XCTAssertTrue(opened)
        XCTAssertFalse(repeated)
        let after = await calls.snapshot()
        XCTAssertEqual(after.workspaces.count, 1)
        XCTAssertEqual(after.prompts, ["新开一个 Agent\n研究 A+B & C"])
        XCTAssertTrue(model.openingRequested)
    }

    /// Verifies an independent suggestion reaches the launcher as No Folder for either app.
    func testFolderlessConfirmationPreservesNativeDestinationAndTask() async {
        for application in AgentDesktopApplication.allCases {
            let calls = NewTaskCallRecorder()
            let ready = AgentNewTaskPreparation(
                projects: [], suggestedProjectID: AgentNewTaskService.independentProjectID,
                suggestedApplication: application, installedApplications: [application], needsProjectChoice: false
            )
            let model = AgentNewTaskViewModel(prepare: { _, _ in ready }, open: { app, destination, text in
                await calls.open(app, directory: destination, prompt: text)
            })
            _ = model.begin("整理这次研究\nA+B & C")
            await model.load(context: context)
            let opened = await model.openConfirmedDraft()
            XCTAssertTrue(opened)
            let result = await calls.snapshot()
            XCTAssertEqual(result.destinations, [.nativeNoFolder])
            XCTAssertEqual(result.prompts, ["整理这次研究\nA+B & C"])
        }
    }

    /// Verifies a failed opening does not allocate a different workspace on an explicit retry.
    func testRetryUsesSameDraftWorkspace() async {
        let calls = NewTaskCallRecorder()
        let ready = preparation()
        let model = AgentNewTaskViewModel(prepare: { _, _ in ready }, workspace: { project, id in
            await calls.workspace(project, id: id)
            return .project(URL(fileURLWithPath: "/fixture/task"))
        }, open: { _, _, _ in throw AgentDesktopLauncherError.launchFailed(.codex) })
        _ = model.begin("新建任务")
        await model.load(context: context)
        let first = await model.openConfirmedDraft()
        let second = await model.openConfirmedDraft()
        XCTAssertFalse(first); XCTAssertFalse(second)
        let result = await calls.snapshot()
        XCTAssertEqual(result.workspaces.count, 2)
        XCTAssertEqual(result.workspaces.first?.1, result.workspaces.last?.1)
        XCTAssertNotNil(model.failure)
    }

    /// Verifies an unavailable requested app and oversized text cannot reach native opening.
    func testUnavailableProviderAndOversizedPromptStayReviewable() async {
        let ready = preparation(application: .claudeCode)
        let model = AgentNewTaskViewModel(prepare: { _, _ in ready }, workspace: { _, _ in
            XCTFail("Must not allocate storage")
            return .project(URL(fileURLWithPath: "/fixture"))
        }, open: { _, _, _ in XCTFail("Must not open") }, maximumPromptUTF16: 10)
        _ = model.begin("新建任务")
        await model.load(context: context)
        XCTAssertEqual(model.application, .claudeCode)
        XCTAssertFalse(model.canOpen)
        model.application = .codex
        XCTAssertTrue(model.canOpen)
        model.text = String(repeating: "🙂", count: 6)
        XCTAssertFalse(model.canOpen)
        let opened = await model.openConfirmedDraft()
        XCTAssertFalse(opened)
    }

    /// Verifies cancellation during storage preparation cannot subsequently open a native app.
    func testCancellationBeforeLaunchSuppressesLateOpening() async {
        let gate = NewTaskWorkspaceGate()
        let ready = preparation()
        let model = AgentNewTaskViewModel(prepare: { _, _ in ready }, workspace: { _, _ in await gate.wait() },
                                         open: { _, _, _ in XCTFail("Cancelled draft must not open") })
        _ = model.begin("新建任务")
        await model.load(context: context)
        let pending = Task { await model.openConfirmedDraft() }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.isOpening)
        XCTAssertFalse(model.begin("不要替换打开中的草稿"))
        model.cancel()
        await gate.release()
        let opened = await pending.value
        XCTAssertFalse(opened)
        XCTAssertFalse(model.openingRequested)
    }

    /// Verifies a superseded suggestion cannot replace the newer task or its selected project.
    func testLatePreparationCannotOverwriteNewerDraft() async {
        let gate = NewTaskPreparationGate()
        let first = preparation(project: "/fixture/old")
        let second = preparation(project: "/fixture/new")
        let model = AgentNewTaskViewModel(prepare: { text, _ in
            if text == "old" { return await gate.wait() }
            return second
        })
        _ = model.begin("old")
        let pending = Task { await model.load(context: context) }
        await gate.waitUntilEntered()
        _ = model.begin("new")
        await model.load(context: context)
        await gate.release(first)
        await pending.value
        XCTAssertEqual(model.text, "new")
        XCTAssertEqual(model.projectID, "/fixture/new")
        XCTAssertFalse(model.isPreparing)
    }

    /// Verifies labels are rendered anew for both supported languages, with no persisted copy.
    func testEveryNewTaskLabelSupportsLiveLanguageRendering() {
        for label in AgentNewTaskCopy.Label.allCases {
            let chinese = AgentNewTaskCopy.text(label, language: .zh)
            let english = AgentNewTaskCopy.text(label, language: .en)
            XCTAssertFalse(chinese.isEmpty)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(chinese, english)
        }
        XCTAssertEqual(AgentRouterResult(outcome: .newTaskPrepared).historyStatus, "agent_new_task_prepared")
        XCTAssertFalse(AgentRouterResult(outcome: .newTaskPrepared).handled)
    }
}

private actor NewTaskCallRecorder {
    private var workspaces: [(String, UUID)] = []
    private var prompts: [String] = []
    private var destinations: [AgentNewTaskDestination] = []
    /// Records allocation requests without creating directories.
    func workspace(_ project: String, id: UUID) { workspaces.append((project, id)) }
    /// Records native opening arguments without launching applications.
    func open(_ application: AgentDesktopApplication, directory: AgentNewTaskDestination, prompt: String) {
        destinations.append(directory)
        prompts.append(prompt)
    }
    /// Returns immutable call observations for assertions.
    func snapshot() -> (workspaces: [(String, UUID)], prompts: [String], destinations: [AgentNewTaskDestination]) {
        (workspaces, prompts, destinations)
    }
}

private actor NewTaskWorkspaceGate {
    private var continuation: CheckedContinuation<AgentNewTaskDestination, Never>?
    private var entry: CheckedContinuation<Void, Never>?
    /// Holds the workspace result so cancellation can be exercised deterministically.
    func wait() async -> AgentNewTaskDestination {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entry?.resume(); entry = nil
        }
    }
    /// Waits for the operation to enter the storage boundary.
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entry = $0 }
    }
    /// Releases storage preparation without touching the filesystem.
    func release() { continuation?.resume(returning: .project(URL(fileURLWithPath: "/fixture/task"))); continuation = nil }
}

private actor NewTaskPreparationGate {
    private var continuation: CheckedContinuation<AgentNewTaskPreparation, Never>?
    private var entry: CheckedContinuation<Void, Never>?
    /// Holds one suggestion independently of a replacement draft.
    func wait() async -> AgentNewTaskPreparation {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entry?.resume(); entry = nil
        }
    }
    /// Waits until the old preparation is suspended.
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entry = $0 }
    }
    /// Delivers the stale result for generation-check assertions.
    func release(_ value: AgentNewTaskPreparation) { continuation?.resume(returning: value); continuation = nil }
}
