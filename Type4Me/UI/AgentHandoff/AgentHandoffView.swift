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
        case .send: copy = ("发送历史并继续", "Send history and continue")
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
        case .voiceInstructionHint: copy = ("已带入本次语音要求。请选择来源和接收会话，核对后再发送。", "Your voice request is included. Choose the source and receiving conversations, then review before sending.")
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

    private let catalogLoader: CatalogLoader
    private let historyLoader: HistoryLoader
    private let sender: Sender
    private let opener: Opener
    private let discarder: Discarder
    private var generation = 0
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
    init(
        catalogLoader: @escaping CatalogLoader = { try AgentSessionCatalog.shared.loadSessions() },
        historyLoader: @escaping HistoryLoader = { try await AgentHandoffHistoryService.shared.load(source: $0) },
        sender: @escaping Sender = { try await AgentHandoffDeliveryService.shared.send(history: $0, target: $1, instruction: $2) },
        opener: @escaping Opener = {
            try await AgentDesktopLauncherService.shared.open(application: $0.application, sessionID: $0.sessionID)
        },
        discarder: @escaping Discarder = { await AgentHandoffHistoryService.shared.discardUnsent($0) }
    ) {
        self.catalogLoader = catalogLoader
        self.historyLoader = historyLoader
        self.sender = sender
        self.opener = opener
        self.discarder = discarder
    }

    var source: AgentSessionDescriptor? { sessions.first { $0.id == sourceID } }
    var target: AgentSessionDescriptor? { sessions.first { $0.id == targetID } }
    var isBusy: Bool { operation != .idle }
    var isSending: Bool { operation == .sending }
    var canSend: Bool {
        guard !isBusy, let history, let source, let target,
              history.source.id == source.id, source.id != target.id,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return deliveredRequest != request(history: history, target: target, instruction: instruction)
    }

    /// Starts a separate voice draft without reusing a previous draft's conversation selections.
    ///
    /// Args:
    ///   text: The original recognized voice request, preserved without rewriting.
    ///
    /// Returns:
    ///   Whether the draft was accepted. Active delivery or navigation keeps its existing state.
    @discardableResult
    func beginVoiceDraft(_ text: String) -> Bool {
        guard !isSending, operation != .openingTarget,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        generation &+= 1
        discardCurrentPreview()
        sourceID = nil
        targetID = nil
        sourceFilter = ""
        targetFilter = ""
        receipt = nil
        failure = nil
        deliveredRequest = nil
        operation = .idle
        voiceInstruction = text
        instruction = text
        return true
    }

    /// Chooses a source and invalidates every preview tied to a previous selection.
    ///
    /// Args:
    ///   id: Native catalog identity of the selected source, or nil.
    func selectSource(_ id: String?) {
        guard !isSending, sourceID != id else { return }
        generation &+= 1
        sourceID = id
        if targetID == id { targetID = nil }
        discardCurrentPreview()
        receipt = nil
        failure = nil
        operation = .idle
    }

    /// Chooses a receiver without implying an automatic send or desktop launch.
    ///
    /// Args:
    ///   id: Native catalog identity of the receiver, or nil.
    func selectTarget(_ id: String?) {
        guard !isSending, targetID != id else { return }
        targetID = id
        receipt = nil
        failure = nil
    }

    /// Refreshes native metadata while preserving still-valid user selections.
    ///
    /// Returns:
    ///   Nothing. Newer selections prevent stale responses from replacing the list.
    func refreshSessions() async {
        guard !isBusy else { return }
        generation &+= 1
        let token = generation
        let previousSource = source
        let previousTarget = target
        operation = .loadingSessions
        failure = nil
        do {
            let loader = catalogLoader
            let result = try await Task.detached(priority: .userInitiated) { try loader() }.value
            guard generation == token else { return }
            sessions = result.sessions
            unavailableApplications = result.unavailableApplications
            if source == nil { sourceID = nil }
            if target == nil { targetID = nil }
            if source != previousSource { discardCurrentPreview(); receipt = nil }
            if target != previousTarget { receipt = nil }
        } catch {
            guard generation == token else { return }
            failure = AgentHandoffUIFailure(label: .catalogFailed, underlying: error)
        }
        if generation == token { operation = .idle }
    }

    /// Loads history only for the source explicitly chosen by the user.
    ///
    /// Returns:
    ///   Nothing. Selection changes invalidate late history responses.
    func loadHistory() async {
        guard !isBusy, let source else { return }
        generation &+= 1
        let token = generation
        operation = .loadingHistory
        discardCurrentPreview()
        receipt = nil
        failure = nil
        do {
            let result = try await historyLoader(source)
            guard generation == token, sourceID == source.id else {
                await discarder(result)
                return
            }
            guard result.source.id == source.id else {
                await discarder(result)
                guard generation == token, sourceID == source.id else { return }
                failure = AgentHandoffUIFailure(label: .historyFailed, underlying: nil)
                operation = .idle
                return
            }
            history = result
            historyWasSubmitted = false
        } catch {
            guard generation == token else { return }
            failure = AgentHandoffUIFailure(label: .historyFailed, underlying: error)
        }
        if generation == token { operation = .idle }
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
        guard !isBusy, let target, target.canOpenExistingConversation else { return }
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
        generation &+= 1
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
        .task { await model.refreshSessions() }
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

    /// Builds a title-filtered native session list with explicit selection.
    ///
    /// Args:
    ///   isSource: Whether this column chooses the history source or receiver.
    ///
    /// Returns:
    ///   A column sharing MyType's settings typography and palette.
    private func sessionColumn(isSource: Bool) -> some View {
        let query = isSource ? model.sourceFilter : model.targetFilter
        let sessions = AgentHandoffViewModel.filtered(model.sessions, query: query)
        let selectedID = isSource ? model.sourceID : model.targetID
        return VStack(alignment: .leading, spacing: TF.spacingSM) {
            Text(copy(isSource ? .source : .target)).font(.system(size: 15, weight: .semibold))
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
                            if isSource { model.selectSource(session.id) } else { model.selectTarget(session.id) }
                        } label: {
                            HStack(alignment: .top, spacing: TF.spacingSM) {
                                Image(systemName: selectedID == session.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedID == session.id ? TF.settingsNavActive : TF.settingsTextTertiary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: TF.spacingXS) {
                                    Text(AgentSessionDescriptor.displayTitle(session.title, language: language))
                                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        .foregroundStyle(TF.settingsText)
                                    HStack {
                                        Text(session.application.displayName)
                                        Spacer(minLength: TF.spacingSM)
                                        Text(AgentHandoffCopy.timestamp(Date(timeIntervalSince1970: session.updatedAt), language: language))
                                    }
                                    .font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
                                    Text(String(session.sessionID.suffix(8)))
                                        .font(.system(size: 10)).foregroundStyle(TF.settingsTextTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(TF.spacingMD)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedID == session.id ? TF.settingsSidebarActive : Color.clear,
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
            Text(copy(isSource ? .chooseSource : .chooseTarget))
                .font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: TF.spacingSM) {
            HStack {
                Text(copy(.history)).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { Task { await model.loadHistory() } } label: {
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
            .disabled(model.isBusy || model.target?.canOpenExistingConversation != true)
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
