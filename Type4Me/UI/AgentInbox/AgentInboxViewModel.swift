import Foundation
import Combine

enum AgentInboxCopy {
    enum Label: CaseIterable {
        case title, subtitle, close, emptyTitle, emptyDetail, unread, open, opening
        case openFailed, cannotOpen, storageFailed, dismiss, dismissHint, showInbox, entryDetail
        case running, waiting, idle, completed, interrupted, failed, unknown, input, approval
    }

    /// Renders queue copy without translating conversation titles or native messages.
    ///
    /// Args:
    ///   label: Semantic UI label.
    ///   language: Currently selected interface language.
    ///
    /// Returns:
    ///   Chinese or English display text.
    static func text(_ label: Label, language: AppLanguage) -> String {
        let values: (String, String)
        switch label {
        case .title: values = ("Agent 消息", "Agent inbox")
        case .subtitle: values = ("完成时提醒，也可随时查看工作状态。", "Notifies you on completion. Check work in progress anytime.")
        case .showInbox: values = ("打开消息队列", "Open agent inbox")
        case .entryDetail: values = ("查看 Agent 进度、完成消息和待办请求", "View agent progress, results, and requests")
        case .close: values = ("收起消息队列", "Hide inbox")
        case .emptyTitle: values = ("消息会出现在这里", "Your agents’ updates appear here")
        case .emptyDetail: values = ("Codex 和 Claude 的工作状态会自动更新，任务完成时提醒你。", "Codex and Claude activity updates automatically. The inbox appears when a task finishes.")
        case .unread: values = ("未读", "Unread")
        case .open: values = ("打开会话继续回复", "Open conversation to reply")
        case .opening: values = ("正在打开会话…", "Opening conversation…")
        case .openFailed: values = ("会话未能打开，请检查对应应用后重试。", "Could not open this conversation. Check its app and try again.")
        case .cannotOpen: values = ("暂时无法定位原会话，请到对应应用查看。", "This conversation cannot be opened directly yet. Check its app.")
        case .storageFailed: values = ("消息记录暂未保存，重启后可能无法保留。", "Updates could not be saved and may not survive a restart.")
        case .dismiss: values = ("从队列移除", "Remove from inbox")
        case .dismissHint: values = ("仅隐藏这条消息，不会结束会话或批准操作。", "Hides this update without stopping the conversation or approving anything.")
        case .running: values = ("正在运行", "Working")
        case .waiting: values = ("等待中", "Waiting")
        case .idle: values = ("空闲", "Idle")
        case .completed: values = ("已完成", "Completed")
        case .interrupted: values = ("已中断", "Interrupted")
        case .failed: values = ("遇到问题", "Failed")
        case .unknown: values = ("状态暂不可用", "Status unavailable")
        case .input: values = ("需要你回复", "Needs your reply")
        case .approval: values = ("需要你批准", "Needs approval")
        }
        return language == .zh ? values.0 : values.1
    }

    /// Prioritizes outstanding requests over a completed or idle execution state.
    ///
    /// Args:
    ///   item: Current session state with independent outstanding requests.
    ///
    /// Returns:
    ///   One or more semantic status labels, with approval first when both are pending.
    static func statusLabels(for item: AgentInboxItem) -> [Label] {
        var pending: [Label] = []
        if item.pendingRequests.contains(where: { $0.kind == .approval }) { pending.append(.approval) }
        if item.pendingRequests.contains(where: { $0.kind == .input }) { pending.append(.input) }
        if !pending.isEmpty { return item.status == .unknown ? [.unknown] + pending : pending }
        switch item.status {
        case .running: return [.running]
        case .waiting: return [.waiting]
        case .idle: return [.idle]
        case .completed: return [.completed]
        case .interrupted: return [.interrupted]
        case .failed: return [.failed]
        case .unknown: return [.unknown]
        }
    }

    /// Builds an accessible row label in the active UI language.
    ///
    /// Args:
    ///   item: Queue item whose original title is preserved.
    ///   language: Active interface language.
    ///
    /// Returns:
    ///   Provider, title, statuses and unread information.
    static func accessibilityLabel(for item: AgentInboxItem, language: AppLanguage) -> String {
        var parts = [item.session.application.displayName,
                     AgentSessionDescriptor.displayTitle(item.session.title, language: language)]
        parts += statusLabels(for: item).map { text($0, language: language) }
        if item.isUnread { parts.append(text(.unread, language: language)) }
        return parts.joined(separator: ", ")
    }
}

@MainActor
final class AgentInboxViewModel: ObservableObject {
    typealias Opener = @MainActor (AgentSessionDescriptor) async throws -> Void

    @Published private(set) var openingID: String?
    @Published private(set) var failedID: String?
    @Published private(set) var failure: AgentInboxCopy.Label?
    private let opener: Opener
    private let markRead: (AgentInboxItem) -> Void
    private let onOpened: () -> Void
    private let presentationRevision: () -> Int
    private var generation = 0

    /// Creates a queue navigator with replaceable app launching and read receipts.
    ///
    /// Args:
    ///   opener: Opens the exact original conversation; production never substitutes a directory.
    ///   markRead: Acknowledges only the selected inbox update after opening is accepted.
    ///   onOpened: Collapses the originating presentation after successful navigation.
    ///   presentationRevision: Identifies new presentations that an older launch must not close.
    init(
        opener: @escaping Opener = { session in
            try await AgentDesktopLauncherService.shared.open(
                application: session.application, projectURL: nil, sessionID: session.sessionID
            )
        },
        markRead: @escaping (AgentInboxItem) -> Void,
        onOpened: @escaping () -> Void = {},
        presentationRevision: @escaping () -> Int = { 0 }
    ) {
        self.opener = opener
        self.markRead = markRead
        self.onOpened = onOpened
        self.presentationRevision = presentationRevision
    }

    /// Opens an exact session when the user selects its queue row.
    ///
    /// Args:
    ///   item: Selected queue snapshot, including its native identity.
    ///
    /// Returns:
    ///   Nothing. Failed launches retain the unread state and display localized feedback.
    func open(_ item: AgentInboxItem) async {
        guard openingID == nil else { return }
        failure = nil
        failedID = nil
        guard item.session.canOpenExistingConversation else {
            failedID = item.id
            failure = .cannotOpen
            return
        }
        openingID = item.id
        let token = generation
        let openingPresentation = presentationRevision()
        do {
            try await opener(item.session)
            try Task.checkCancellation()
            guard generation == token else { return }
            openingID = nil
            markRead(item)
            // A newer completion or manual reveal owns its own presentation.
            if presentationRevision() == openingPresentation { onOpened() }
        } catch {
            guard generation == token else { return }
            openingID = nil
            if error is CancellationError { return }
            failedID = item.id
            failure = .openFailed
        }
    }

    /// Invalidates pending presentation callbacks when the panel is explicitly closed.
    ///
    /// Returns:
    ///   Nothing. Native sessions and persisted queue items remain unchanged.
    func resetPresentation() {
        generation &+= 1
        openingID = nil
        failedID = nil
        failure = nil
    }
}
