import AppKit
import Foundation

enum AgentNewTaskCopy {
    enum Label: CaseIterable {
        case title, task, project, independent, chooseProject, chooseFolder, application
        case preparing, opening, cancel, sendInApp, unavailable, invalidTask, failed
        case projectHint, independentHint, chooseApplication, notInstalled
    }

    /// Renders only app-provided labels; user tasks and project names remain verbatim.
    ///
    /// Args:
    ///   label: Semantic interface label.
    ///   language: Currently selected MyType language.
    ///
    /// Returns:
    ///   Chinese or English interface text.
    static func text(_ label: Label, language: AppLanguage) -> String {
        let pair: (String, String)
        switch label {
        case .title: pair = ("新建 Agent", "New agent")
        case .task: pair = ("让它做什么", "What should it do?")
        case .project: pair = ("在哪个项目", "Project")
        case .independent: pair = ("无文件夹", "No Folder")
        case .chooseProject: pair = ("请选择项目", "Choose a project")
        case .chooseFolder: pair = ("选择其他项目…", "Choose another project…")
        case .application: pair = ("使用", "Use")
        case .preparing: pair = ("正在选择项目…", "Finding the project…")
        case .opening: pair = ("正在打开…", "Opening…")
        case .cancel: pair = ("取消", "Cancel")
        case .sendInApp: pair = ("到应用中发送", "Open to send")
        case .unavailable: pair = ("没能确定项目，请选一下。", "Choose the project for this task.")
        case .invalidTask: pair = ("请填写简短的任务要求。", "Enter a short task request.")
        case .failed: pair = ("未能确认打开，请查看对应应用后再试。", "Opening was not confirmed. Check the app before retrying.")
        case .projectHint: pair = ("新会话使用项目文件，发送后开始。", "The new conversation uses this project's files. Send there to begin.")
        case .independentHint: pair = ("不关联已有项目，发送后开始。", "No existing project is selected. Send there to begin.")
        case .chooseApplication: pair = ("请选择应用", "Choose an app")
        case .notInstalled: pair = ("未安装", "Not installed")
        }
        return language == .zh ? pair.0 : pair.1
    }
}

/// Holds one editable new-task draft; preparation never creates a workspace or opens an app.
@MainActor
final class AgentNewTaskViewModel: ObservableObject {
    typealias Preparer = @Sendable (String, AgentNewTaskContext) async throws -> AgentNewTaskPreparation
    typealias WorkspaceResolver = @Sendable (String, UUID) async throws -> AgentNewTaskDestination
    typealias Opener = @Sendable (AgentDesktopApplication, AgentNewTaskDestination, String) async throws -> Void

    @Published var text = ""
    @Published var projectID: String?
    @Published var application: AgentDesktopApplication?
    @Published private(set) var projects: [AgentNewTaskProject] = []
    @Published private(set) var installedApplications: [AgentDesktopApplication] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var isOpening = false
    @Published private(set) var openingRequested = false
    @Published private(set) var needsProjectChoice = false
    @Published private(set) var failure: Error?
    private var generation = UUID()
    private let prepare: Preparer
    private let workspace: WorkspaceResolver
    private let open: Opener
    private let maximumPromptUTF16: Int

    /// Injects side-effect boundaries so cancellation and duplicate submissions can be tested.
    ///
    /// Args:
    ///   prepare: Bounded metadata/search-based suggestions.
    ///   workspace: Resolves storage only on explicit confirmation.
    ///   open: Native deep-link request, never an automatic first-message submission.
    ///   maximumPromptUTF16: Hard input bound aligned with the native launcher.
    init(
        prepare: @escaping Preparer = { try await AgentNewTaskService.shared.prepare($0, context: $1) },
        workspace: @escaping WorkspaceResolver = { project, id in
            try await Task.detached { try AgentNewTaskWorkspace().resolve(projectID: project, draftID: id) }.value
        },
        open: @escaping Opener = { try await AgentDesktopLauncherService.shared.openNewTask(application: $0, destination: $1, prompt: $2) },
        maximumPromptUTF16: Int = AgentDesktopLauncherService.Configuration().maximumNewTaskPromptUTF16Units
    ) {
        self.prepare = prepare
        self.workspace = workspace
        self.open = open
        self.maximumPromptUTF16 = maximumPromptUTF16
    }

    var canOpen: Bool {
        !isPreparing && !isOpening && !openingRequested && projectID != nil
            && application.map { installedApplications.contains($0) } == true
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf16.count <= maximumPromptUTF16
    }

    /// Starts a fresh draft without replacing one already being opened.
    ///
    /// Args:
    ///   text: Original voice request.
    ///
    /// Returns:
    ///   Whether the draft was accepted.
    func begin(_ text: String) -> Bool {
        guard !isOpening else { return false }
        generation = UUID()
        self.text = text
        projectID = nil; application = nil; projects = []; installedApplications = []
        failure = nil; needsProjectChoice = false; isPreparing = true; openingRequested = false
        return true
    }

    /// Applies suggestions only to the draft that requested them.
    ///
    /// Args:
    ///   context: Native foreground evidence captured before MyType presents a window.
    func load(context: AgentNewTaskContext) async {
        let token = generation
        let original = text
        do {
            let result = try await prepare(original, context)
            guard token == generation, !Task.isCancelled else { return }
            projects = result.projects
            projectID = result.suggestedProjectID
            application = result.suggestedApplication
            installedApplications = result.installedApplications
            needsProjectChoice = result.needsProjectChoice
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            failure = error
            needsProjectChoice = true
            installedApplications = AgentDesktopLauncherService.shared.detectInstallations()
                .filter(\.isInstalled).map(\.application)
            application = context.application ?? installedApplications.first
        }
        guard token == generation else { return }
        isPreparing = false
    }

    /// Adds an explicitly selected existing directory without teaching the model a new path.
    ///
    /// Args:
    ///   url: Directory returned by the native folder chooser.
    func chooseProject(_ url: URL) {
        guard !isPreparing, !isOpening else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if !projects.contains(where: { $0.id == canonical.path }) {
            projects.append(AgentNewTaskProject(id: canonical.path, name: canonical.lastPathComponent,
                                               recentTitles: [], updatedAt: Date().timeIntervalSince1970))
        }
        projectID = canonical.path
        needsProjectChoice = false
    }

    /// Opens the confirmed draft once and leaves actual submission to the native application.
    ///
    /// Returns:
    ///   True only when macOS accepted the opening request, not when an Agent started work.
    func openConfirmedDraft() async -> Bool {
        guard canOpen, let projectID, let application else { return false }
        let token = generation
        let prompt = text
        isOpening = true; failure = nil
        defer { if token == generation { isOpening = false } }
        do {
            try Task.checkCancellation()
            let directory = try await workspace(projectID, token)
            try Task.checkCancellation()
            guard token == generation else { return false }
            try await open(application, directory, prompt)
            guard token == generation else { return false }
            openingRequested = true
            return true
        } catch {
            guard token == generation else { return false }
            if !(error is CancellationError) { failure = error }
            return false
        }
    }

    /// Invalidates pending suggestions without deleting files or closing a native agent.
    func cancel() {
        generation = UUID()
        isPreparing = false; isOpening = false
    }
}
