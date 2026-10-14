import AppKit
import Foundation
import Observation
import SwiftUI

enum AgentHandoffCopy {
    enum Label: CaseIterable {
        case title, subtitle, source, target, findTitle, refresh, loadingSessions
        case chooseSource, chooseTarget, noSessions, noMatches, history, loadHistory, loadingHistory
        case instruction, instructionHint, send, sending, openTarget, openingTarget
        case catalogFailed, historyFailed, deliveryFailed, launchFailed, catalogPartial
        case claudeMustBeOpen, filePermission, historyPrivacy, queued, delivered, deliveryNotice
        case previewLimited, sameSession, missingInstruction, voiceInstructionHint
        case findingSuggestions, suggested, manuallySelected, changeSelection, hideChoices
        case similarCandidates, suggestionsUnavailable, missingSuggestion, suggestionMatch
    }

    /// Renders interface labels using the currently observed language.
    ///
    /// Args:
    ///   label: Stable interface label.
    ///   language: Current MyType language.
    ///
    /// Returns:
    ///   Chinese or English text without translating user-entered content.
    nonisolated static func text(_ label: Label, language: AppLanguage) -> String {
        let copy: (String, String)
        switch label {
        case .title: copy = ("交接会话", "Hand off a conversation")
        case .subtitle: copy = ("把已有的工作交给另一个会话，接着做下一步。", "Send existing work to another conversation and continue with the next step.")
        case .source: copy = ("历史来自", "History from")
        case .target: copy = ("发送给", "Send to")
        case .findTitle: copy = ("查找会话标题", "Find a conversation title")
        case .refresh: copy = ("刷新会话", "Refresh conversations")
        case .loadingSessions: copy = ("正在读取会话…", "Loading conversations…")
        case .chooseSource: copy = ("选择提供历史的会话", "Choose the conversation to share")
        case .chooseTarget: copy = ("选择接着工作的会话", "Choose the conversation to continue the work")
        case .noSessions: copy = ("先在 Codex 或 Claude Code 中创建会话，再刷新。", "Create a conversation in Codex or Claude Code, then refresh.")
        case .noMatches: copy = ("没有这个标题的会话，请换一个关键词。", "No matching conversation title. Try another word.")
        case .history: copy = ("可见对话预览", "Visible conversation preview")
        case .loadHistory: copy = ("读取完整历史", "Load full history")
        case .loadingHistory: copy = ("正在更新并读取历史…", "Updating and loading history…")
        case .instruction: copy = ("接下来做什么", "What should happen next?")
        case .instructionHint: copy = ("写下接收会话需要继续完成的工作。", "Describe the work the receiving conversation should continue.")
        case .send: copy = ("确认交接", "Confirm handoff")
        case .sending: copy = ("正在发送…", "Sending…")
        case .openTarget: copy = ("打开接收会话", "Open receiving conversation")
        case .openingTarget: copy = ("正在打开…", "Opening…")
        case .catalogFailed: copy = ("会话列表读取失败，请刷新重试。", "Could not load conversations. Refresh and try again.")
        case .historyFailed: copy = ("历史读取失败，请重新读取。", "Could not load history. Load it again.")
        case .deliveryFailed: copy = ("本次发送未确认成功，请查看接收会话后再决定是否重试。", "Delivery was not confirmed. Check the receiving conversation before deciding whether to retry.")
        case .launchFailed: copy = ("接收会话未能打开，请检查对应应用。", "Could not open the receiving conversation. Check its app.")
        case .catalogPartial: copy = ("部分应用的会话列表或打开能力暂不可用", "Some apps' conversation lists or opening capabilities are unavailable")
        case .claudeMustBeOpen: copy = ("Claude 的接收会话需先在桌面应用中打开。打开后，再点击发送。", "Open the receiving Claude conversation in the desktop app first, then send.")
        case .filePermission: copy = ("历史较长，已通过文件发送。Claude 可能需要你在它的应用里允许读取。", "The long history was sent as a file. Claude may ask you to allow reading it in its app.")
        case .historyPrivacy: copy = ("发送完整的用户与模型可见正文，不包含工具详情；正文中原有的个人信息也会一并发送。", "Sends all visible user and assistant text, without tool details. Personal information already in that text is included.")
        case .queued: copy = ("已加入 Codex 的会话队列", "Added to the Codex conversation queue")
        case .delivered: copy = ("已投递到 Claude 的会话消息通道", "Delivered to Claude's conversation message channel")
        case .deliveryNotice: copy = ("请到接收会话查看回复。投递成功不代表 Agent 已读或已完成。", "Check the receiving conversation for its response. Delivery does not mean the agent has read it or finished.")
        case .previewLimited: copy = ("这里只展示历史开头，发送时包含完整历史。", "Only the beginning is shown here. Delivery includes the full history.")
        case .sameSession: copy = ("来源和接收会话需要不同。", "Choose different source and receiving conversations.")
        case .missingInstruction: copy = ("请填写下一步要做的工作。", "Describe the next task before sending.")
        case .voiceInstructionHint: copy = ("已根据语音建议来源和接收会话，可更换；确认后才会发送。", "Conversations are suggested from your voice request. You can change them; nothing is sent until you confirm.")
        case .findingSuggestions: copy = ("正在查找来源和接收会话…", "Finding source and receiving conversations…")
        case .suggested: copy = ("建议会话", "Suggested conversation")
        case .manuallySelected: copy = ("你选择的会话", "Your selection")
        case .changeSelection: copy = ("更换会话", "Change conversation")
        case .hideChoices: copy = ("收起候选", "Hide alternatives")
        case .similarCandidates: copy = ("还有相近的会话，请核对两端；需要时可更换。", "There are similar conversations. Review both selections and change them if needed.")
        case .suggestionsUnavailable: copy = ("暂时无法完成建议排序，请核对候选或自行选择。", "Suggestions could not be ranked. Review the candidates or choose conversations yourself.")
        case .missingSuggestion: copy = ("没有找到合适的建议，可从下方选择会话。", "No suitable suggestion was found. Choose a conversation below.")
        case .suggestionMatch: copy = ("相关对话", "Matching conversation text")
        }
        return language == .zh ? copy.0 : copy.1
    }

    /// Describes the loaded snapshot without suggesting that later messages are included.
    ///
    /// Args:
    ///   history: Loaded history snapshot.
    ///   language: Current MyType language.
    ///
    /// Returns:
    ///   Message count and archive timestamp for review before delivery.
    nonisolated static func snapshot(_ history: AgentHandoffHistory, language: AppLanguage) -> String {
        let date = timestamp(history.snapshotDate, language: language)
        return language == .zh
            ? "\(history.messageCount) 条可见消息，历史更新于 \(date)"
            : "\(history.messageCount) visible messages; history updated \(date)"
    }

    /// Formats dates consistently with the interface language.
    ///
    /// Args:
    ///   date: Session activity or snapshot timestamp.
    ///   language: Current MyType language.
    ///
    /// Returns:
    ///   Localized date and time.
    nonisolated static func timestamp(_ date: Date, language: AppLanguage) -> String {
        date.formatted(Date.FormatStyle()
            .year().month(.abbreviated).day().hour().minute()
            .locale(Locale(identifier: language == .zh ? "zh_CN" : "en_US")))
    }
}

enum AgentHandoffUIOperation: Equatable {
    case idle, loadingSessions, loadingHistory, sending, openingTarget
}

struct AgentHandoffUIFailure {
    let label: AgentHandoffCopy.Label
    let underlying: Error?

    /// Renders stored error semantics again after an interface language change.
    ///
    /// Args:
    ///   language: Current MyType language.
    ///
    /// Returns:
    ///   A provider-specific explanation or a localized action hint.
    func message(language: AppLanguage) -> String {
        if let error = underlying as? AgentHandoffHistoryError { return error.message(language: language) }
        if let error = underlying as? AgentHandoffDeliveryError { return error.message(language: language) }
        if let error = underlying as? AgentDesktopLauncherError { return error.message(language: language) }
        return AgentHandoffCopy.text(label, language: language)
    }
}

@MainActor
@Observable
final class AgentHandoffViewModel {
    typealias CatalogLoader = @Sendable () throws -> AgentSessionCatalogSnapshot
    typealias HistoryLoader = @Sendable (AgentSessionDescriptor) async throws -> AgentHandoffHistory
    typealias Sender = @Sendable (AgentHandoffHistory, AgentSessionDescriptor, String) async throws -> AgentHandoffDeliveryReceipt
    typealias Opener = @Sendable (AgentSessionDescriptor) async throws -> Void
    typealias Discarder = @Sendable (AgentHandoffHistory) async -> Void
    typealias Suggester = @Sendable (String, [AgentSessionDescriptor]) async throws -> AgentHandoffSuggestion

    private let catalogLoader: CatalogLoader
    private let historyLoader: HistoryLoader
    private let sender: Sender
    private let opener: Opener
    private let discarder: Discarder
    private let suggester: Suggester
    private var generation = 0
    private var historyGeneration = 0
    private var suggestionTask: Task<AgentHandoffSuggestion, Error>?
    private var historyTask: Task<Void, Never>?
    private var sourceWasManuallySelected = false
    private var targetWasManuallySelected = false
    private var deliveredRequest: DeliveredRequest?
    private var historyWasSubmitted = false

    private(set) var sessions: [AgentSessionDescriptor] = []
    private(set) var unavailableApplications: [AgentDesktopApplication] = []
    private(set) var sourceID: String?
    private(set) var targetID: String?
    private(set) var history: AgentHandoffHistory?
    private(set) var receipt: AgentHandoffDeliveryReceipt?
    private(set) var failure: AgentHandoffUIFailure?
    private(set) var operation = AgentHandoffUIOperation.idle
    private(set) var voiceInstruction: String?
    private(set) var isSuggesting = false
    private(set) var sourceCandidates: [AgentHandoffSuggestionCandidate] = []
    private(set) var targetCandidates: [AgentHandoffSuggestionCandidate] = []
    private(set) var suggestionNotice: AgentHandoffSuggestionNotice?
    private(set) var suggestionFailed = false
    private(set) var sourceWasSuggested = false
    private(set) var targetWasSuggested = false
    var sourceFilter = ""
    var targetFilter = ""
    var instruction = "" {
        didSet {
            if instruction != oldValue { receipt = nil; failure = nil }
        }
    }

    private struct DeliveredRequest: Equatable {
        let sourceID: String
        let targetID: String
        let snapshotDate: Date
        let instruction: String
    }

    /// Creates a handoff model using existing session, history, and delivery services.
    ///
    /// Args:
    ///   catalogLoader: Metadata reader; dispatched off the main actor.
    ///   historyLoader: Explicit source history loader.
    ///   sender: Native message delivery implementation.
    ///   opener: Exact existing-chat desktop navigation.
    ///   discarder: Removes only application-owned snapshots that have never been submitted.
    ///   suggester: Finds and ranks native source and receiving conversations without sending.
    init(
        catalogLoader: @escaping CatalogLoader = { try AgentSessionCatalog.shared.loadSessions() },
        historyLoader: @escaping HistoryLoader = { try await AgentHandoffHistoryService.shared.load(source: $0) },
        sender: @escaping Sender = { try await AgentHandoffDeliveryService.shared.send(history: $0, target: $1, instruction: $2) },
        opener: @escaping Opener = {
            try await AgentDesktopLauncherService.shared.open(application: $0.application, sessionID: $0.sessionID)
        },
        discarder: @escaping Discarder = { await AgentHandoffHistoryService.shared.discardUnsent($0) },
        suggester: @escaping Suggester = { try await AgentHandoffSuggestionService.shared.suggest($0, sessions: $1) }
    ) {
        self.catalogLoader = catalogLoader
        self.historyLoader = historyLoader
        self.sender = sender
        self.opener = opener
        self.discarder = discarder
        self.suggester = suggester
    }

    var source: AgentSessionDescriptor? { sessions.first { $0.id == sourceID } }
    var target: AgentSessionDescriptor? { sessions.first { $0.id == targetID } }
    var isBusy: Bool { operation != .idle }
    var isSending: Bool { operation == .sending }
    var canSend: Bool {
        guard !isBusy, !isSuggesting, let history, let source, let target,
              history.source.id == source.id, source.id != target.id,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return deliveredRequest != request(history: history, target: target, instruction: instruction)
    }

    /// Starts a separate voice draft and invalidates work associated with an older request.
    ///
    /// Args:
    ///   text: Original recognized request, preserved as the editable instruction.
    ///
    /// Returns:
    ///   Whether the draft was accepted. Active delivery or navigation remains unchanged.
    @discardableResult
    func beginVoiceDraft(_ text: String) -> Bool {
        guard !isSending, operation != .openingTarget,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        invalidatePendingWork()
        discardCurrentPreview()
        sourceID = nil
        targetID = nil
        sourceFilter = ""
        targetFilter = ""
        sourceWasManuallySelected = false
        targetWasManuallySelected = false
        sourceWasSuggested = false
        targetWasSuggested = false
        sourceCandidates = []
        targetCandidates = []
        suggestionNotice = nil
        suggestionFailed = false
        receipt = nil
        failure = nil
        deliveredRequest = nil
        operation = .idle
        voiceInstruction = text
        instruction = text
        return true
    }

    /// Keeps a manual source selection authoritative and prepares its history automatically.
    ///
    /// Args:
    ///   id: Native source identity, or nil to clear the selected source.
    func selectSource(_ id: String?) {
        guard !isSending, operation != .openingTarget else { return }
        sourceWasManuallySelected = true
        sourceWasSuggested = false
        let validID = sessions.contains { $0.id == id } ? id : nil
        guard sourceID != validID else { return }
        invalidateHistoryLoad()
        sourceID = validID
        if targetID == validID { targetID = nil; targetWasSuggested = false }
        discardCurrentPreview()
        receipt = nil
        failure = nil
        startHistoryLoading()
    }

    /// Keeps a manual receiver selection authoritative without sending or opening a conversation.
    ///
    /// Args:
    ///   id: Native receiving identity, or nil to clear the selected receiver.
    func selectTarget(_ id: String?) {
        guard !isSending, operation != .openingTarget else { return }
        targetWasManuallySelected = true
        targetWasSuggested = false
        let validID = id != sourceID && sessions.contains { $0.id == id } ? id : nil
        guard targetID != validID else { return }
        targetID = validID
        receipt = nil
        failure = nil
    }

    /// Refreshes metadata, suggests both ends of a voice draft, and prepares its selected history.
    ///
    /// Returns:
    ///   Nothing. New drafts, catalog refreshes, or window closure invalidate every late result.
    func refreshSessions() async {
        guard !isSending, operation != .openingTarget, !Task.isCancelled else { return }
        invalidatePendingWork()
        let token = generation
        let previousSource = source
        let previousTarget = target
        operation = .loadingSessions
        failure = nil
        do {
            let loader = catalogLoader
            let result = try await Task.detached(priority: .userInitiated) { try loader() }.value
            guard generation == token, !Task.isCancelled else { return }
            sessions = result.sessions
            unavailableApplications = result.unavailableApplications
            if source == nil { sourceID = nil; sourceWasSuggested = false }
            if target == nil { targetID = nil; targetWasSuggested = false }
            if source != previousSource { discardCurrentPreview(); receipt = nil }
            if target != previousTarget { receipt = nil }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            operation = .idle
            failure = AgentHandoffUIFailure(label: .catalogFailed, underlying: error)
            return
        }
        operation = .idle
        if let voiceInstruction {
            await suggestConversations(voiceInstruction, generation: token)
        }
        guard generation == token, !Task.isCancelled else { return }
        if history == nil { await loadHistory() }
    }

    /// Loads or joins the selected source's preview without ever submitting it.
    ///
    /// Args:
    ///   forceReload: Whether an explicit reload should replace an already prepared snapshot.
    ///
    /// Returns:
    ///   Nothing. Source changes cancel pending loads and discard stale snapshots.
    func loadHistory(forceReload: Bool = false) async {
        guard !isSending, operation != .openingTarget, operation != .loadingSessions else { return }
        if let historyTask { await historyTask.value; return }
        if !forceReload, let history, history.source.id == sourceID { return }
        invalidateHistoryLoad()
        discardCurrentPreview()
        receipt = nil
        failure = nil
        startHistoryLoading()
        await historyTask?.value
    }

    /// Ranks both sides independently while preserving each side the user has already changed.
    ///
    /// Args:
    ///   text: Original voice request used only for finding candidates.
    ///   token: Draft and catalog generation that must still be active on completion.
    private func suggestConversations(_ text: String, generation token: Int) async {
        isSuggesting = true
        suggestionFailed = false
        suggestionNotice = nil
        sourceCandidates = []
        targetCandidates = []
        let suggester = suggester
        let catalog = sessions
        let task = Task {
            try Task.checkCancellation()
            return try await suggester(text, catalog)
        }
        suggestionTask = task
        do {
            let result = try await task.value
            guard generation == token, !Task.isCancelled else { return }
            sourceCandidates = validCandidates(result.sources)
            targetCandidates = validCandidates(result.targets)
            suggestionNotice = result.notice
            if !sourceWasManuallySelected {
                let proposed = sourceCandidates.first { $0.session.id == result.sourceID }?.session.id
                // A manually chosen receiver takes precedence over an overlapping suggested source.
                let chosen = targetWasManuallySelected && proposed == targetID ? nil : proposed
                if sourceID != chosen {
                    invalidateHistoryLoad()
                    discardCurrentPreview()
                    sourceID = chosen
                    receipt = nil
                }
                sourceWasSuggested = chosen != nil
            }
            if !targetWasManuallySelected {
                let proposed = targetCandidates.first { $0.session.id == result.targetID }?.session.id
                targetID = proposed != sourceID ? proposed : nil
                targetWasSuggested = targetID != nil
                receipt = nil
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            suggestionFailed = true
        }
        guard generation == token else { return }
        suggestionTask = nil
        isSuggesting = false
    }

    /// Keeps suggestion evidence tied to the current native catalog, with no duplicate identities.
    ///
    /// Args:
    ///   candidates: Ranked metadata and visible snippets returned by the suggestion service.
    ///
    /// Returns:
    ///   Candidates whose identities remain in the loaded native catalog.
    private func validCandidates(_ candidates: [AgentHandoffSuggestionCandidate]) -> [AgentHandoffSuggestionCandidate] {
        let validIDs = Set(sessions.map(\.id))
        var seen = Set<String>()
        return candidates.filter { validIDs.contains($0.session.id) && seen.insert($0.session.id).inserted }
    }

    /// Starts exactly one preview operation for the currently selected source.
    ///
    /// Returns:
    ///   Nothing. Results can update the draft only while both source and generation still match.
    private func startHistoryLoading() {
        guard operation != .loadingSessions, !isSending, operation != .openingTarget,
              let source, historyTask == nil else { return }
        let token = historyGeneration
        let draft = generation
        operation = .loadingHistory
        historyTask = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == draft, historyGeneration == token else { return }
            do {
                let result = try await historyLoader(source)
                guard generation == draft, historyGeneration == token, sourceID == source.id,
                      !Task.isCancelled else {
                    await discarder(result)
                    return
                }
                guard result.source.id == source.id else {
                    await discarder(result)
                    guard generation == draft, historyGeneration == token else { return }
                    failure = AgentHandoffUIFailure(label: .historyFailed, underlying: nil)
                    operation = .idle
                    historyTask = nil
                    return
                }
                history = result
                historyWasSubmitted = false
            } catch {
                guard generation == draft, historyGeneration == token, !Task.isCancelled else { return }
                failure = AgentHandoffUIFailure(label: .historyFailed, underlying: error)
            }
            guard generation == draft, historyGeneration == token else { return }
            operation = .idle
            historyTask = nil
        }
    }

    /// Invalidates only source history so a manual source change does not cancel receiver suggestions.
    private func invalidateHistoryLoad() {
        historyGeneration &+= 1
        historyTask?.cancel()
        historyTask = nil
        if operation == .loadingHistory { operation = .idle }
    }

    /// Cancels pending suggestions and previews before a new draft, catalog, or closed window.
    private func invalidatePendingWork() {
        generation &+= 1
        suggestionTask?.cancel()
        suggestionTask = nil
        isSuggesting = false
        invalidateHistoryLoad()
    }

    /// Lists suggested conversations first while keeping every catalog conversation available.
    ///
    /// Args:
    ///   isSource: Whether to use source or receiver suggestion order.
    ///   query: Optional user-entered title filter.
    ///
    /// Returns:
    ///   Ranked native sessions, followed by the remaining catalog in its original order.
    func choices(isSource: Bool, query: String) -> [AgentSessionDescriptor] {
        let candidates = isSource ? sourceCandidates : targetCandidates
        let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.session.id, $0) })
        let ranked = sessions.enumerated().sorted { lhs, rhs in
            let left = order[lhs.element.id] ?? candidates.count + lhs.offset
            let right = order[rhs.element.id] ?? candidates.count + rhs.offset
            return left < right
        }.map(\.element)
        return Self.filtered(ranked, query: query)
    }

    /// Delivers one reviewed history snapshot after the user explicitly requests it.
    ///
    /// Returns:
    ///   Nothing. Accepted requests cannot be resent unchanged from this view.
    func send() async {
        guard canSend, let history, let target else { return }
        let instruction = instruction
        let submitted = request(history: history, target: target, instruction: instruction)
        operation = .sending
        failure = nil
        receipt = nil
        do {
            // Preserve the file after any delivery attempt: a thrown error may follow partial submission.
            historyWasSubmitted = true
            receipt = try await sender(history, target, instruction)
            deliveredRequest = submitted
        } catch {
            failure = AgentHandoffUIFailure(label: .deliveryFailed, underlying: error)
        }
        operation = .idle
    }

    /// Opens the selected native conversation without creating or resuming a duplicate.
    ///
    /// Returns:
    ///   Nothing. Sending remains a separate user action.
    func openTarget() async {
        guard !isBusy, !isSuggesting, let target, target.canOpenExistingConversation else { return }
        let token = generation
        operation = .openingTarget
        failure = nil
        do {
            try await opener(target)
        } catch {
            if generation == token, targetID == target.id {
                failure = AgentHandoffUIFailure(label: .launchFailed, underlying: error)
            }
        }
        if generation == token { operation = .idle }
    }

    /// Releases an unused preview when its window closes without touching submitted history.
    ///
    /// Returns:
    ///   Nothing. Pending loads are invalidated and their late results are discarded separately.
    func clearUnsentPreview() {
        invalidatePendingWork()
        discardCurrentPreview()
        if !isSending { operation = .idle }
    }

    /// Clears a preview and schedules cleanup only before the first delivery attempt.
    ///
    /// Returns:
    ///   Nothing. Accepted and uncertain submissions retain their files for the receiving agent.
    private func discardCurrentPreview() {
        let previous = history
        let shouldDiscard = !historyWasSubmitted
        history = nil
        historyWasSubmitted = false
        guard let previous, shouldDiscard else { return }
        let discarder = discarder
        Task { await discarder(previous) }
    }

    /// Filters display titles while keeping providers and native identities separate.
    ///
    /// Args:
    ///   sessions: Available native conversations.
    ///   query: User-entered title filter.
    ///
    /// Returns:
    ///   Conversations in their original order, including equal-titled conversations.
    nonisolated static func filtered(_ sessions: [AgentSessionDescriptor], query: String) -> [AgentSessionDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Builds the identity of an explicit send to suppress accidental duplicate clicks.
    ///
    /// Args:
    ///   history: Reviewed source snapshot.
    ///   target: Chosen native receiving conversation.
    ///   instruction: User-entered next task.
    ///
    /// Returns:
    ///   Stable identity independent of interface language and display titles.
    private func request(history: AgentHandoffHistory, target: AgentSessionDescriptor, instruction: String) -> DeliveredRequest {
        DeliveredRequest(sourceID: history.source.id, targetID: target.id, snapshotDate: history.snapshotDate,
                         instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
struct AgentHandoffView: View {
    // Preview is bounded independently of export: rendering a multi-megabyte SwiftUI Text can stall the window.
    private static let maximumPreviewCharacters = 8000
    @State private var model: AgentHandoffViewModel
    @State private var showsPreview = false
    @State private var showsSourceChoices = false
    @State private var showsTargetChoices = false
    @AppStorage("tf_language") private var languageRaw = AppLanguage.systemDefault
    @AppStorage(SettingsTheme.storageKey) private var themeRaw = SettingsTheme.defaultValue.rawValue

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .en }

    /// Hosts a shared draft so menu and voice entry points use the same window state.
    ///
    /// Args:
    ///   model: The draft owned by the shared handoff window controller.
    init(model: AgentHandoffViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TF.spacingXL) {
            header
            if model.isSuggesting {
                HStack(spacing: TF.spacingSM) {
                    ProgressView().controlSize(.small)
                    Text(copy(.findingSuggestions)).font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: TF.spacingXL) {
                    HStack(alignment: .top, spacing: TF.spacingXL) {
                        sessionColumn(isSource: true)
                        sessionColumn(isSource: false)
                    }
                    historySection
                    instructionSection
                    feedback
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(TF.spacingXL)
        .frame(minWidth: 940, minHeight: 680)
        .background(TF.settingsWindowBackground)
        .background(AgentHandoffWindowAppearance(theme: SettingsTheme.resolve(themeRaw), title: copy(.title)))
        .foregroundStyle(TF.settingsText)
        .preferredColorScheme(SettingsTheme.resolve(themeRaw).colorScheme)
        .onDisappear { model.clearUnsentPreview() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: TF.spacingSM) {
                Text(copy(.title)).font(.system(size: 26, weight: .semibold))
                Text(copy(.subtitle)).font(.system(size: 13)).foregroundStyle(TF.settingsTextSecondary)
            }
            Spacer()
            Button { Task { await model.refreshSessions() } } label: {
                Label(copy(.refresh), systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
        }
    }

    /// Shows the selected conversation above an optional list of suggested and other sessions.
    ///
    /// Args:
    ///   isSource: Whether the column chooses the history source or receiver.
    ///
    /// Returns:
    ///   A reviewable selection using MyType's existing settings typography and palette.
    private func sessionColumn(isSource: Bool) -> some View {
        let query = isSource ? model.sourceFilter : model.targetFilter
        let sessions = model.choices(isSource: isSource, query: query)
        let selected = isSource ? model.source : model.target
        let showChoices = selected == nil || (isSource ? showsSourceChoices : showsTargetChoices)
        return VStack(alignment: .leading, spacing: TF.spacingSM) {
            HStack {
                Text(copy(isSource ? .source : .target)).font(.system(size: 15, weight: .semibold))
                Spacer()
                if selected != nil {
                    Button(copy(showChoices ? .hideChoices : .changeSelection)) {
                        if isSource { showsSourceChoices.toggle() } else { showsTargetChoices.toggle() }
                    }
                    .disabled(model.isSending)
                }
            }
            if let selected {
                VStack(alignment: .leading, spacing: TF.spacingSM) {
                    Text(copy((isSource ? model.sourceWasSuggested : model.targetWasSuggested) ? .suggested : .manuallySelected))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(TF.settingsNavActive)
                    sessionDetails(selected, isSource: isSource)
                }
                .padding(TF.spacingMD)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TF.settingsSidebarActive, in: RoundedRectangle(cornerRadius: TF.cornerMD))
            } else if model.voiceInstruction != nil, !model.isSuggesting, model.operation != .loadingSessions {
                Text(copy(.missingSuggestion)).font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
            }
            if showChoices {
                TextField(copy(.findTitle), text: isSource ? $model.sourceFilter : $model.targetFilter)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSending)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TF.spacingXS) {
                        if sessions.isEmpty {
                            Text(copy(model.operation == .loadingSessions ? .loadingSessions :
                                        (model.sessions.isEmpty ? .noSessions : .noMatches)))
                                .font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
                                .padding(TF.spacingLG).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(sessions) { session in
                            Button {
                                if isSource {
                                    model.selectSource(session.id)
                                    showsSourceChoices = false
                                } else {
                                    model.selectTarget(session.id)
                                    showsTargetChoices = false
                                }
                            } label: {
                                HStack(alignment: .top, spacing: TF.spacingSM) {
                                    Image(systemName: selected?.id == session.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected?.id == session.id ? TF.settingsNavActive : TF.settingsTextTertiary)
                                        .padding(.top, 2)
                                    sessionDetails(session, isSource: isSource)
                                }
                                .padding(TF.spacingMD)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected?.id == session.id ? TF.settingsSidebarActive : Color.clear,
                                            in: RoundedRectangle(cornerRadius: TF.cornerSM))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isSending || (!isSource && session.id == model.sourceID))
                        }
                    }
                    .padding(TF.spacingXS)
                }
                .frame(height: 200)
                .background(TF.settingsSidebar, in: RoundedRectangle(cornerRadius: TF.cornerMD))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders title, app, activity time, and matching visible text for review before confirmation.
    ///
    /// Args:
    ///   session: Exact catalog conversation to describe.
    ///   isSource: Which suggestion list supplies the matching text.
    ///
    /// Returns:
    ///   User-facing context without translating titles or original conversation snippets.
    private func sessionDetails(_ session: AgentSessionDescriptor, isSource: Bool) -> some View {
        let candidates = isSource ? model.sourceCandidates : model.targetCandidates
        let candidate = candidates.first { $0.session.id == session.id }
        return VStack(alignment: .leading, spacing: TF.spacingXS) {
            Text(AgentSessionDescriptor.displayTitle(session.title, language: language))
                .font(.system(size: 13, weight: .medium)).lineLimit(2).foregroundStyle(TF.settingsText)
            HStack {
                Text(session.application.displayName)
                Spacer(minLength: TF.spacingSM)
                Text(AgentHandoffCopy.timestamp(Date(timeIntervalSince1970: session.updatedAt), language: language))
            }
            .font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
            if let candidate, !candidate.snippet.isEmpty {
                Text(candidate.snippet).font(.system(size: 12)).lineLimit(3)
                    .foregroundStyle(TF.settingsTextSecondary)
                    .accessibilityLabel(copy(.suggestionMatch) + ": " + candidate.snippet)
            }
            Text(String(session.sessionID.suffix(8)))
                .font(.system(size: 10)).foregroundStyle(TF.settingsTextTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: TF.spacingSM) {
            HStack {
                Text(copy(.history)).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { Task { await model.loadHistory(forceReload: true) } } label: {
                    if model.operation == .loadingHistory {
                        HStack { ProgressView().controlSize(.small); Text(copy(.loadingHistory)) }
                    } else {
                        Text(copy(.loadHistory))
                    }
                }
                .disabled(model.isBusy || model.source == nil)
            }
            if let history = model.history {
                Text(AgentHandoffCopy.snapshot(history, language: language))
                    .font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
                DisclosureGroup(isExpanded: $showsPreview) {
                    ScrollView {
                        Text(String(history.markdown.prefix(Self.maximumPreviewCharacters)))
                            .font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(TF.spacingMD)
                    }
                    .frame(maxHeight: 140)
                    .background(TF.settingsSidebar, in: RoundedRectangle(cornerRadius: TF.cornerSM))
                } label: {
                    Text(copy(.history)).font(.system(size: 12))
                }
                if history.markdown.prefix(Self.maximumPreviewCharacters + 1).count > Self.maximumPreviewCharacters {
                    Text(copy(.previewLimited)).font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
                }
            } else {
                Text(copy(.chooseSource)).font(.system(size: 12)).foregroundStyle(TF.settingsTextTertiary)
            }
        }
    }

    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: TF.spacingSM) {
            Text(copy(.instruction)).font(.system(size: 15, weight: .semibold))
            TextEditor(text: $model.instruction)
                .font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(TF.spacingSM).frame(minHeight: 80, maxHeight: 120)
                .background(TF.settingsSidebar, in: RoundedRectangle(cornerRadius: TF.cornerMD))
                .overlay(RoundedRectangle(cornerRadius: TF.cornerMD).stroke(TF.settingsBorder, lineWidth: 1))
                .accessibilityLabel(copy(.instruction))
                .disabled(model.isSending)
            Text(copy(model.voiceInstruction == nil ? .instructionHint : .voiceInstructionHint))
                .font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if model.suggestionFailed {
            Label(copy(.suggestionsUnavailable), systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(TF.settingsAccentAmber)
        } else if let notice = model.suggestionNotice {
            switch notice {
            case .ambiguous:
                Text(copy(.similarCandidates)).font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
            case .rankingUnavailable:
                Text(copy(.suggestionsUnavailable)).font(.system(size: 12)).foregroundStyle(TF.settingsAccentAmber)
            }
        }
        if !model.unavailableApplications.isEmpty {
            Text(copy(.catalogPartial) + ": " + model.unavailableApplications.map(\.displayName).joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(TF.settingsAccentAmber)
        }
        if model.target?.application == .claudeCode, model.receipt == nil {
            Text(copy(.claudeMustBeOpen)).font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
        }
        if let failure = model.failure {
            Label(failure.message(language: language), systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(TF.settingsAccentRed).textSelection(.enabled)
        }
        if let receipt = model.receipt {
            VStack(alignment: .leading, spacing: TF.spacingXS) {
                Label(copy(receipt.route == .codexQueue ? .queued : .delivered), systemImage: "checkmark.circle")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TF.settingsAccentGreen)
                Text(copy(.deliveryNotice)).font(.system(size: 12)).foregroundStyle(TF.settingsTextSecondary)
                if receipt.target.application == .claudeCode, receipt.usesHistoryFile {
                    Text(copy(.filePermission)).font(.system(size: 12)).foregroundStyle(TF.settingsAccentAmber)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: TF.spacingLG) {
            Text(copy(.historyPrivacy)).font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await model.openTarget() } } label: {
                Text(copy(model.operation == .openingTarget ? .openingTarget : .openTarget))
            }
            .disabled(model.isBusy || model.isSuggesting || model.target?.canOpenExistingConversation != true)
            Button { Task { await model.send() } } label: {
                HStack {
                    if model.isSending { ProgressView().controlSize(.small) }
                    Text(copy(model.isSending ? .sending : .send))
                }
            }
            .buttonStyle(.borderedProminent).tint(TF.settingsNavActive)
            .disabled(!model.canSend)
        }
    }

    /// Resolves each label at render time so an open window follows language changes.
    ///
    /// Args:
    ///   label: Stable label to render.
    ///
    /// Returns:
    ///   Copy in the language currently selected in MyType.
    private func copy(_ label: AgentHandoffCopy.Label) -> String {
        AgentHandoffCopy.text(label, language: language)
    }
}

private struct AgentHandoffWindowAppearance: NSViewRepresentable {
    let theme: SettingsTheme
    let title: String

    /// Creates a view that applies the settings appearance when attached to its window.
    ///
    /// Args:
    ///   context: SwiftUI host context.
    ///
    /// Returns:
    ///   An invisible appearance observer.
    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.theme = theme
        view.title = title
        return view
    }

    /// Updates both window chrome and content after a settings-theme change.
    ///
    /// Args:
    ///   nsView: Attached appearance observer.
    ///   context: SwiftUI host context.
    func updateNSView(_ nsView: AppearanceView, context: Context) {
        nsView.theme = theme
        nsView.title = title
    }

    final class AppearanceView: NSView {
        var theme = SettingsTheme.defaultValue {
            didSet { window?.appearance = theme.appearance }
        }
        var title = "" {
            didSet { window?.title = title }
        }

        /// Applies the most recent theme after SwiftUI attaches this view to a window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = theme.appearance
            window?.title = title
        }
    }
}
