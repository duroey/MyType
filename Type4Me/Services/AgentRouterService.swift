import Foundation

extension Notification.Name {
    static let agentActivityRoutingFinished = Notification.Name("mytype.agentActivityRoutingFinished")
}

enum AgentHistorySearchPreference {
    static let storageKey = "tf_agentHistorySearchEnabled"
    static let defaultEnabled = true

    /// Reads the user's history-search preference without changing saved settings.
    ///
    /// Returns:
    ///   Whether spoken activity queries should search historical messages.
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }
}

struct AgentRouterResult: Equatable, Sendable {
    enum Outcome: String, Sendable {
        case requestedOpen, openedWithoutContinuation, matchedPreview, selectionRequired, noMatch, noSessions
        case noPreviousActivity, noPendingSelection, unsupported, cancelled, failed, catalogUnavailable
        case historySearchUnavailable, historyMappingUnavailable, handoffPrepared, handoffBusy
        case historyIndexUpdating
        case newTaskPrepared, newTaskBusy
    }

    let outcome: Outcome
    let activityTitle: String?
    let application: AgentDesktopApplication?
    let unavailableApplications: [AgentDesktopApplication]

    /// Creates semantic feedback that can be rendered after a language change.
    ///
    /// Args:
    ///   outcome: Routing action or reason it could not proceed.
    ///   activityTitle: User or application title, kept verbatim.
    ///   application: Provider of the selected session.
    ///   unavailableApplications: Providers whose catalog or navigation is unavailable.
    init(
        outcome: Outcome, activityTitle: String? = nil,
        application: AgentDesktopApplication? = nil,
        unavailableApplications: [AgentDesktopApplication] = []
    ) {
        self.outcome = outcome
        self.activityTitle = activityTitle
        self.application = application
        self.unavailableApplications = unavailableApplications
    }

    var handled: Bool { outcome == .requestedOpen || outcome == .openedWithoutContinuation }
    var message: String { message(language: AppLanguage.current) }
    var historyStatus: String {
        switch outcome {
        case .requestedOpen, .openedWithoutContinuation: return "agent_launched"
        case .matchedPreview: return "agent_matched"
        case .selectionRequired: return "agent_selection_required"
        case .handoffPrepared: return "agent_handoff_prepared"
        case .handoffBusy: return "agent_handoff_busy"
        case .newTaskPrepared: return "agent_new_task_prepared"
        case .newTaskBusy: return "agent_new_task_busy"
        case .historyIndexUpdating: return "agent_index_updating"
        case .cancelled: return "discarded"
        case .unsupported: return "agent_session_unsupported"
        case .failed, .catalogUnavailable, .historySearchUnavailable, .historyMappingUnavailable: return "agent_launch_failed"
        default: return "agent_no_match"
        }
    }

    /// Renders feedback without claiming that a desktop chat or message was verified.
    ///
    /// Args:
    ///   language: Current UI language.
    ///
    /// Returns:
    ///   Localized action feedback.
    func message(language: AppLanguage) -> String {
        let zh = language == .zh
        let title = activityTitle.map { AgentSessionDescriptor.displayTitle($0, language: language) }
            ?? (zh ? "这件事" : "this activity")
        let app = application?.displayName ?? "Agent"
        switch outcome {
        case .requestedOpen:
            return zh ? "已请求打开「\(title)」的 \(app) 会话。" : "Requested the \(app) conversation for “\(title)”."
        case .openedWithoutContinuation:
            return zh ? "已请求打开「\(title)」，但无法记住继续目标。" : "Requested “\(title)”, but could not remember it for continuation."
        case .matchedPreview:
            return zh ? "匹配到「\(title)」的 \(app) 会话。" : "Matched the \(app) conversation for “\(title)”."
        case .selectionRequired:
            return zh ? "请选择具体会话，也可以再说“第一个”。" : "Choose a conversation, or say “the first one”."
        case .noMatch:
            let base = zh ? "没有找到足够匹配的事情，请换个称呼或查看事情列表。" : "No confident activity match. Try another name or browse activities."
            guard !unavailableApplications.isEmpty else { return base }
            let names = unavailableApplications.map(\.displayName).joined(separator: ", ")
            return base + (zh ? " \(names) 的会话列表或原会话定位暂不可用。" : " \(names) catalog or existing-chat navigation is unavailable.")
        case .noSessions:
            return zh ? "没有找到可用的会话，请先在 Agent 中开始一项任务。" : "No available conversations were found. Start a task in your agent first."
        case .noPreviousActivity:
            return zh ? "没有可继续的上次会话，请先查找这件事。" : "There is no previous conversation to continue. Find the activity first."
        case .noPendingSelection:
            return zh ? "当前没有这个编号，请按列表中的编号选择。" : "That number is unavailable. Choose a number shown in the list."
        case .unsupported:
            return zh ? "暂不能从外部定位 \(app) 的这个原会话。" : "This existing \(app) conversation cannot be located externally yet."
        case .cancelled:
            return zh ? "已取消 Agent 操作。" : "Agent action cancelled."
        case .failed:
            return zh ? "无法打开该会话或保存事情索引，请检查应用后重试。" : "Could not open the conversation or save the activities index. Check the app and try again."
        case .catalogUnavailable:
            return zh ? "会话列表暂不可读，原有事情索引已保留。" : "The conversation catalog is unavailable. Existing activity associations were preserved."
        case .handoffPrepared:
            return zh ? "已带入交接要求，请选择来源和接收会话。" : "Handoff request prepared. Choose the source and receiving conversations."
        case .handoffBusy:
            return zh ? "交接窗口正在处理另一项操作，请完成后再试。" : "The handoff window is busy. Finish its current operation and try again."
        case .newTaskPrepared:
            return zh ? "请确认新任务的项目。" : "Review the project for the new task."
        case .newTaskBusy:
            return zh ? "正在打开另一个新任务，请稍后再试。" : "Another new task is opening. Try again shortly."
        case .historySearchUnavailable:
            return zh ? "历史内容搜索暂不可用，请稍后再试。" : "History search is unavailable. Try again later."
        case .historyIndexUpdating:
            return zh ? "暂未找到匹配；会话索引尚未确认完整，请查看设置中的索引状态。" : "No match found yet. Index coverage is not confirmed; check its status in Settings."
        case .historyMappingUnavailable:
            return zh ? "找到了历史记录，但暂时无法定位它的桌面原会话。" : "History was found, but its original desktop conversation could not be located."
        }
    }
}

struct AgentActivityQuery: Equatable, Sendable {
    enum Intent: Equatable, Sendable {
        case search(String, continuing: Bool), browse, continueLast, ordinal(Int), cancel
    }
    let intent: Intent

    /// Parses navigation words without treating directories or arbitrary text as commands.
    ///
    /// Args:
    ///   text: Final spoken transcript.
    ///
    /// Returns:
    ///   Activity search or an explicit continuation/selection command.
    static func parse(_ text: String) -> AgentActivityQuery {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        let lower = value.lowercased()
        if ["取消", "取消选择", "算了", "cancel"].contains(lower) { return Self(intent: .cancel) }
        if ["查看事情", "查看所有事情", "事情列表", "show activities", "list activities"].contains(lower) {
            return Self(intent: .browse)
        }
        if ["继续", "继续上次", "继续刚才", "继续刚才那个", "刚才那个", "继续这件事", "回到刚才",
            "continue", "continue last", "continue the last one"].contains(lower) {
            return Self(intent: .continueLast)
        }
        let chinese = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let english = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        for index in chinese.indices {
            let n = index + 1
            let forms = ["第\(chinese[index])个", "第\(n)个", "选\(n)", "选择第\(chinese[index])个",
                         "打开第\(chinese[index])个", "\(english[index])", "the \(english[index]) one", "\(n)"]
            if forms.contains(lower) { return Self(intent: .ordinal(n)) }
        }
        for prefix in ["继续", "continue "] where lower.hasPrefix(prefix) {
            let query = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(intent: .search(query, continuing: true))
        }
        for prefix in ["切换到", "打开", "查找", "找到", "进入", "找", "go to ", "open ", "find "] where lower.hasPrefix(prefix) {
            return Self(intent: .search(
                String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines), continuing: false
            ))
        }
        return Self(intent: .search(value, continuing: false))
    }
}

/// Routes activities to stable existing-session identities, independently of directories.
actor AgentRouterService {
    typealias CatalogProvider = @Sendable () async throws -> AgentSessionCatalogSnapshot
    typealias SessionOpener = @Sendable (AgentSessionDescriptor) async throws -> Void
    typealias RenameHandler = @Sendable (UUID, String) async throws -> Void
    typealias LinkHandler = @Sendable (String, UUID) async throws -> Void
    typealias CandidateChooser = @MainActor @Sendable (
        String, [AgentActivityCandidate], @escaping RenameHandler, @escaping LinkHandler
    ) async -> AgentActivityCandidate?
    typealias ResultSink = @Sendable (AgentRouterResult) -> Void
    typealias ContentSearchProvider = @Sendable (String) async throws -> [AgentsViewSearchHit]?

    struct Configuration: Sendable {
        var maximumCandidates = 40
        var maximumSuggestedCandidates = 5
        var maximumRecentSuggestions = 2
    }
    private struct PendingSelection {
        let id: UUID
        let query: String
        var candidates: [AgentActivityCandidate]
        let launch: Bool
    }

    static let shared = AgentRouterService(contentSearchProvider: { query in
        guard AgentHistorySearchPreference.isEnabled else { return nil }
        let hits = try await AgentsViewSearchService.shared.search(query)
        if hits.isEmpty, await MainActor.run(body: { AgentIndexService.shared.searchMayBeIncomplete }) {
            throw AgentsViewSearchError.indexUpdating
        }
        return hits
    })
    private let store: AgentActivityStore
    private let catalogProvider: CatalogProvider
    private let opener: SessionOpener
    private let chooser: CandidateChooser
    private let resultSink: ResultSink
    private let matcher: AgentFuzzyMatcher
    private let configuration: Configuration
    private let contentSearchProvider: ContentSearchProvider?
    private var generation = 0
    private var pendingSelection: PendingSelection?
    private var chooserTask: Task<Void, Never>?
    private var openingTask: Task<Bool, Error>?
    private var openingOwner: Int?
    private var editTask: Task<Void, Error>?
    private var editTaskID: UUID?

    /// Creates a router with replaceable metadata, UI, and navigation boundaries.
    ///
    /// Args:
    ///   store: Serialized persistent activity associations.
    ///   catalogProvider: Bounded metadata-only session loader.
    ///   opener: Existing-session navigation request.
    ///   chooser: Asynchronous candidate panel.
    ///   resultSink: Receives the later outcome of a panel choice.
    ///   matcher: Existing similarity scores and confidence limits.
    ///   configuration: Candidate list bound.
    ///   contentSearchProvider: Optional history lookup; nil keeps isolated metadata routing.
    init(
        store: AgentActivityStore = .shared,
        catalogProvider: @escaping CatalogProvider = {
            let worker = Task.detached(priority: .utility) { try AgentSessionCatalog.shared.loadSessions() }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        },
        opener: @escaping SessionOpener = { session in
            try await AgentDesktopLauncherService.shared.open(application: session.application, sessionID: session.sessionID)
        },
        chooser: @escaping CandidateChooser = { query, candidates, rename, link in
            await AgentActivityPickerPanelController.shared.choose(
                query: query, candidates: candidates, onRename: rename, onLink: link
            )
        },
        resultSink: @escaping ResultSink = {
            NotificationCenter.default.post(name: .agentActivityRoutingFinished, object: $0)
        },
        matcher: AgentFuzzyMatcher = AgentFuzzyMatcher(),
        configuration: Configuration = Configuration(),
        contentSearchProvider: ContentSearchProvider? = nil
    ) {
        precondition(configuration.maximumCandidates > 0 && configuration.maximumSuggestedCandidates > 0)
        precondition(configuration.maximumRecentSuggestions >= 0)
        self.store = store
        self.catalogProvider = catalogProvider
        self.opener = opener
        self.chooser = chooser
        self.resultSink = resultSink
        self.matcher = matcher
        self.configuration = configuration
        self.contentSearchProvider = contentSearchProvider
    }

    /// Searches activities or resolves a frozen pending choice without blocking recording.
    ///
    /// Args:
    ///   text: Activity name or explicit selection/continuation command.
    ///   launch: Whether to request desktop navigation.
    ///
    /// Returns:
    ///   Immediate action result; a panel's eventual choice is reported to resultSink.
    func handle(_ text: String, launch: Bool = true) async -> AgentRouterResult {
        generation += 1
        let owner = generation
        guard !Task.isCancelled else { return AgentRouterResult(outcome: .cancelled) }
        let intent = AgentActivityQuery.parse(text).intent
        if case .ordinal(let number) = intent {
            if let pending = pendingSelection {
                guard pending.candidates.indices.contains(number - 1) else {
                    return AgentRouterResult(outcome: .noPendingSelection)
                }
                let selected = pending.candidates[number - 1]
                guard selected.canOpen else {
                    return AgentRouterResult(outcome: .unsupported, activityTitle: selected.activityTitle,
                                             application: selected.application)
                }
                clearPendingSelection()
                return await open(selected, launch: launch && pending.launch, owner: owner, queryAlias: pending.query)
            }
            return AgentRouterResult(outcome: .noPendingSelection)
        }
        clearPendingSelection()
        if intent == .cancel { return AgentRouterResult(outcome: .cancelled) }
        do {
            let catalog = try await catalogProvider()
            guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
            guard !catalog.sessions.isEmpty else {
                return AgentRouterResult(
                    outcome: catalog.unavailableApplications.contains(.codex) ? .catalogUnavailable : .noSessions,
                    unavailableApplications: catalog.unavailableApplications
                )
            }
            let snapshot = try await store.reconcile(sessions: catalog.sessions)
            guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
            let candidates = candidates(snapshot: snapshot, sessions: catalog.sessions)
            switch intent {
            case .browse:
                return presentSelection(query: "", candidates: candidates, launch: launch)
            case .continueLast:
                guard let candidate = candidates.first(where: {
                    $0.activityID == snapshot.lastActivityID && $0.session.id == snapshot.lastSessionKey
                }) else { return AgentRouterResult(outcome: .noPreviousActivity) }
                return await open(candidate, launch: launch, owner: owner)
            case .search(let query, let continuing):
                guard !query.isEmpty else { return AgentRouterResult(outcome: .noMatch) }
                if let contentSearchProvider {
                    let remembered = rememberedCandidates(query: query, candidates: candidates, snapshot: snapshot)
                    if remembered.count == 1, let candidate = remembered.first {
                        return await open(candidate, launch: launch, owner: owner)
                    }
                    if !remembered.isEmpty {
                        return presentSelection(query: query, candidates: remembered, launch: launch)
                    }
                    do {
                        let hits = try await contentSearchProvider(query)
                        guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
                        if let hits {
                            guard !hits.isEmpty else { return AgentRouterResult(outcome: .noMatch) }
                            let matched = historyCandidates(hits: hits, candidates: candidates, sessions: catalog.sessions)
                            guard !matched.isEmpty else {
                                return AgentRouterResult(outcome: .historyMappingUnavailable)
                            }
                            // Fusion ranks are not confidence: every content match requires a choice.
                            return presentSelection(query: query, candidates: matched, launch: launch)
                        }
                    } catch is CancellationError {
                        return AgentRouterResult(outcome: .cancelled)
                    } catch AgentsViewSearchError.indexUpdating {
                        return AgentRouterResult(outcome: owns(owner) ? .historyIndexUpdating : .cancelled)
                    } catch {
                        return AgentRouterResult(outcome: owns(owner) ? .historySearchUnavailable : .cancelled)
                    }
                }
                let ranked = rank(query: query, candidates: candidates, snapshot: snapshot)
                guard let best = ranked.first else {
                    return AgentRouterResult(outcome: .noMatch, unavailableApplications: catalog.unavailableApplications)
                }
                if best.score < matcher.threshold {
                    let suggestions = suggestedCandidates(ranked: ranked, recent: candidates)
                    return presentSelection(query: query, candidates: suggestions, launch: launch)
                }
                let secondActivity = ranked.first { $0.activityID != best.activityID }
                let ambiguous = secondActivity.map { best.score - $0.score < matcher.ambiguityMargin } ?? false
                let members = ranked.filter { $0.activityID == best.activityID }
                if !ambiguous {
                    if members.count == 1 { return await open(best, launch: launch, owner: owner) }
                    if continuing, let preferred = snapshot.activities.first(where: { $0.id == best.activityID })?.preferredSessionKey,
                       let selected = members.first(where: { $0.session.id == preferred }) {
                        return await open(selected, launch: launch, owner: owner)
                    }
                }
                let relevant = ranked.filter { $0.score >= matcher.threshold }
                return presentSelection(query: query, candidates: relevant, launch: launch)
            case .ordinal, .cancel:
                return AgentRouterResult(outcome: .cancelled)
            }
        } catch {
            return AgentRouterResult(outcome: owns(owner) ? .catalogUnavailable : .cancelled)
        }
    }

    /// Reuses only exact names the user has explicitly assigned or confirmed by choosing.
    ///
    /// Args:
    ///   query: Parsed spoken activity request.
    ///   candidates: Current native conversations and stable activity associations.
    ///   snapshot: User-provided names and confirmed previous lookup phrases.
    ///
    /// Returns:
    ///   Known targets; multiple targets still require selection. Native titles are not used.
    private func rememberedCandidates(
        query: String, candidates: [AgentActivityCandidate], snapshot: AgentActivitySnapshot
    ) -> [AgentActivityCandidate] {
        let normalized = query.lowercased().filter { !$0.isWhitespace }
        let identities = Set(snapshot.activities.filter { activity in
            ([activity.customTitle].compactMap { $0 } + activity.aliases).contains {
                $0.lowercased().filter { !$0.isWhitespace } == normalized
            }
        }.map(\.id))
        return candidates.filter { identities.contains($0.activityID) }.map {
            AgentActivityCandidate(activityID: $0.activityID, activityTitle: $0.activityTitle,
                                   session: $0.session, score: 1)
        }
    }

    /// Opens the activity browser with the same catalog and selection rules as voice.
    ///
    /// Returns:
    ///   Immediate browser status.
    func browse() async -> AgentRouterResult { await handle("查看事情") }

    /// Cancels only the currently owned chooser; old completion callbacks are ignored.
    func cancelPendingSelection() {
        generation += 1
        clearPendingSelection()
    }

    /// Clears owned UI, navigation and edit tasks after the caller sets its generation.
    private func clearPendingSelection() {
        pendingSelection = nil
        chooserTask?.cancel()
        chooserTask = nil
        openingTask?.cancel()
        openingTask = nil
        openingOwner = nil
        editTask?.cancel()
        editTask = nil
        editTaskID = nil
    }

    /// Warms activity associations using metadata; failures preserve the existing index.
    func reconcileIndexes() async {
        do {
            let catalog = try await catalogProvider()
            guard !Task.isCancelled, !catalog.sessions.isEmpty else { return }
            _ = try await store.reconcile(sessions: catalog.sessions)
        } catch {
            DebugFileLogger.log("agent activity metadata reconcile unavailable; existing index preserved")
        }
    }

    /// Joins stable associations to current native titles without directory labels.
    ///
    /// Args:
    ///   snapshot: Persistent identities and user names.
    ///   sessions: Current provider metadata.
    ///
    /// Returns:
    ///   Recent-first, individually identifiable session candidates.
    private func candidates(snapshot: AgentActivitySnapshot, sessions: [AgentSessionDescriptor]) -> [AgentActivityCandidate] {
        let lookup = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.activities.flatMap { activity -> [AgentActivityCandidate] in
            let members = activity.sessionKeys.compactMap { lookup[$0] }.sorted { $0.updatedAt > $1.updatedAt }
            let title = activity.customTitle ?? members.first?.title ?? ""
            return members.map { AgentActivityCandidate(activityID: activity.id, activityTitle: title, session: $0, score: 0) }
        }.sorted {
            if $0.session.updatedAt != $1.session.updatedAt { return $0.session.updatedAt > $1.session.updatedAt }
            return $0.session.id < $1.session.id
        }
    }

    /// Joins ranked history evidence only to known native desktop conversations.
    ///
    /// Args:
    ///   hits: Ranked historical message matches; their scores are not probabilities.
    ///   candidates: Existing stable activity associations.
    ///   sessions: Native identities used to verify provider and engine mappings.
    ///
    /// Returns:
    ///   Distinct native conversations with transient evidence, without a recency fallback.
    private func historyCandidates(
        hits: [AgentsViewSearchHit], candidates: [AgentActivityCandidate], sessions: [AgentSessionDescriptor]
    ) -> [AgentActivityCandidate] {
        let lookup = Dictionary(candidates.map { ($0.session.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var result: [AgentActivityCandidate] = []
        for hit in hits {
            guard let session = AgentsViewSearchService.nativeSession(for: hit, in: sessions),
                  let candidate = lookup[session.id], seen.insert(session.id).inserted else { continue }
            result.append(AgentActivityCandidate(
                activityID: candidate.activityID, activityTitle: candidate.activityTitle,
                session: session, score: 0,
                evidence: AgentActivityEvidence(snippet: hit.snippet, timestamp: hit.timestamp, ordinal: hit.ordinal)
            ))
            if result.count >= configuration.maximumSuggestedCandidates { break }
        }
        return result
    }

    /// Scores distinct activities while retaining every explicitly associated session.
    ///
    /// Args:
    ///   query: Spoken activity name.
    ///   candidates: Current session candidates.
    ///   snapshot: User-supplied aliases.
    ///
    /// Returns:
    ///   Score-ordered candidates; workspace paths are never scored.
    private func rank(query: String, candidates: [AgentActivityCandidate], snapshot: AgentActivitySnapshot) -> [AgentActivityCandidate] {
        var scores: [UUID: Double] = [:]
        for candidate in candidates {
            let activity = snapshot.activities.first { $0.id == candidate.activityID }
            let texts = [candidate.activityTitle, candidate.session.title]
                + candidate.session.matchTexts + (activity?.aliases ?? [])
            let score = texts.map { matcher.score(query: query, candidate: $0) }.max() ?? 0
            scores[candidate.activityID] = max(scores[candidate.activityID] ?? 0, score)
        }
        return candidates.map {
            AgentActivityCandidate(activityID: $0.activityID, activityTitle: $0.activityTitle, session: $0.session, score: scores[$0.activityID] ?? 0)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.session.updatedAt != $1.session.updatedAt { return $0.session.updatedAt > $1.session.updatedAt }
            return $0.session.id < $1.session.id
        }
    }

    /// Offers textual leads and recent conversations when a spoken name has not been learned.
    ///
    /// Args:
    ///   ranked: All candidates ordered by textual similarity.
    ///   recent: All candidates ordered by recent activity.
    ///
    /// Returns:
    ///   Bounded, unique suggestions requiring explicit selection. Zero-score recent
    ///   sessions stay eligible because a new activity name can differ from its native title.
    private func suggestedCandidates(
        ranked: [AgentActivityCandidate], recent: [AgentActivityCandidate]
    ) -> [AgentActivityCandidate] {
        let limit = configuration.maximumSuggestedCandidates
        guard let best = ranked.first, best.score > 0 else { return Array(recent.prefix(limit)) }
        let recentSlots = min(configuration.maximumRecentSuggestions, limit)
        let scores = Dictionary(ranked.map { ($0.session.id, $0.score) }, uniquingKeysWith: { first, _ in first })
        let recentWithScores = recent.prefix(recentSlots).map {
            AgentActivityCandidate(activityID: $0.activityID, activityTitle: $0.activityTitle,
                                   session: $0.session, score: scores[$0.session.id] ?? 0)
        }
        var seen: Set<String> = []
        return Array((Array(ranked.prefix(limit - recentSlots)) + recentWithScores + ranked)
            .filter { seen.insert($0.session.id).inserted }.prefix(limit))
    }

    /// Presents frozen candidates in a background task, leaving voice input available.
    ///
    /// Args:
    ///   query: Search text shown by the picker.
    ///   candidates: Ranked, stable candidates including unsupported providers.
    ///   launch: Whether a selection may open a desktop conversation.
    ///
    /// Returns:
    ///   Selection-required status.
    private func presentSelection(query: String, candidates: [AgentActivityCandidate], launch: Bool) -> AgentRouterResult {
        guard !candidates.isEmpty else { return AgentRouterResult(outcome: .noSessions) }
        let requestID = UUID()
        var activityOrder: [UUID] = []
        var groups: [UUID: [AgentActivityCandidate]] = [:]
        for candidate in candidates {
            if groups[candidate.activityID] == nil { activityOrder.append(candidate.activityID) }
            groups[candidate.activityID, default: []].append(candidate)
        }
        // Freeze the same group order that the panel renders, so spoken ordinals match visible rows.
        let shown = Array(activityOrder.flatMap { groups[$0] ?? [] }.prefix(configuration.maximumCandidates))
        pendingSelection = PendingSelection(id: requestID, query: query, candidates: shown, launch: launch)
        let chooser = chooser
        chooserTask = Task { [weak self] in
            guard let router = self else { return }
            let selected = await chooser(query, shown, { activityID, name in
                try await router.rename(activityID: activityID, name: name, requestID: requestID)
            }, { key, activityID in
                try await router.link(sessionKey: key, activityID: activityID, requestID: requestID)
            })
            guard !Task.isCancelled else { return }
            await router.finishSelection(requestID: requestID, selected: selected)
        }
        return AgentRouterResult(outcome: .selectionRequired)
    }

    /// Persists an edit only for the active picker and updates its frozen labels.
    ///
    /// Args:
    ///   activityID: Activity selected for naming.
    ///   name: User-entered title.
    ///   requestID: Picker ownership token.
    ///
    /// Throws:
    ///   Stale picker or store validation/persistence error.
    private func rename(activityID: UUID, name: String, requestID: UUID) async throws {
        guard pendingSelection?.id == requestID else { throw AgentActivityStoreError.unknownActivity }
        let store = store
        try await performEdit(requestID: requestID) { try await store.rename(activityID: activityID, title: name) }
        guard pendingSelection?.id == requestID else { throw AgentActivityStoreError.unknownActivity }
        pendingSelection?.candidates = pendingSelection?.candidates.map {
            AgentActivityCandidate(activityID: $0.activityID, activityTitle: $0.activityID == activityID ? name.trimmingCharacters(in: .whitespacesAndNewlines) : $0.activityTitle, session: $0.session, score: $0.score, evidence: $0.evidence)
        } ?? []
    }

    /// Moves an association without changing numbered candidate order or session identity.
    ///
    /// Args:
    ///   sessionKey: Selected provider-qualified identity.
    ///   activityID: Explicit destination activity.
    ///   requestID: Active picker token.
    ///
    /// Throws:
    ///   A stale picker, association, or persistence error.
    private func link(sessionKey: String, activityID: UUID, requestID: UUID) async throws {
        guard let pending = pendingSelection, pending.id == requestID,
              let target = pending.candidates.first(where: { $0.activityID == activityID }) else {
            throw AgentActivityStoreError.unknownActivity
        }
        let store = store
        try await performEdit(requestID: requestID) { try await store.link(sessionKey: sessionKey, to: activityID) }
        guard pendingSelection?.id == requestID else { throw AgentActivityStoreError.unknownActivity }
        pendingSelection?.candidates = pendingSelection?.candidates.map {
            AgentActivityCandidate(activityID: $0.session.id == sessionKey ? activityID : $0.activityID,
                                   activityTitle: $0.session.id == sessionKey ? target.activityTitle : $0.activityTitle,
                                   session: $0.session, score: $0.score, evidence: $0.evidence)
        } ?? []
    }

    /// Resolves a panel callback only if it still owns the displayed request.
    ///
    /// Args:
    ///   requestID: Original picker token.
    ///   selected: Current UI choice, or nil for cancellation.
    private func finishSelection(requestID: UUID, selected: AgentActivityCandidate?) async {
        guard let pending = pendingSelection, pending.id == requestID else { return }
        let candidate = selected.flatMap { selected in
            pending.candidates.first { $0.session.id == selected.session.id }
        }
        pendingSelection = nil
        generation += 1
        let owner = generation
        let result = if let candidate {
            await open(candidate, launch: pending.launch, owner: owner, queryAlias: pending.query)
        } else { AgentRouterResult(outcome: .cancelled) }
        guard owns(owner) else { return }
        chooserTask = nil
        resultSink(result)
    }

    /// Revalidates session identity and association before sending one navigation request.
    ///
    /// Args:
    ///   candidate: Frozen user choice or unambiguous title match.
    ///   launch: Whether to dispatch navigation.
    ///   owner: Request generation that must remain current.
    ///   queryAlias: Optional search phrase confirmed by an explicit picker choice.
    ///
    /// Returns:
    ///   Accepted request status, or a concrete routing failure.
    private func open(_ candidate: AgentActivityCandidate, launch: Bool, owner: Int, queryAlias: String? = nil) async -> AgentRouterResult {
        guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
        do {
            let catalog = try await catalogProvider()
            guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
            let snapshot = try await store.readSnapshot()
            guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
            guard let session = catalog.sessions.first(where: { $0.id == candidate.session.id }),
                  snapshot.activities.contains(where: { $0.id == candidate.activityID && $0.sessionKeys.contains(session.id) }) else {
                return AgentRouterResult(outcome: .noMatch)
            }
            guard session.canOpenExistingConversation else {
                return AgentRouterResult(outcome: .unsupported, activityTitle: candidate.activityTitle, application: session.application)
            }
            guard launch else {
                return AgentRouterResult(outcome: .matchedPreview, activityTitle: candidate.activityTitle, application: session.application)
            }
            let opener = opener
            let store = store
            let task = Task {
                try Task.checkCancellation()
                try await opener(session)
                guard self.owns(owner) else { throw CancellationError() }
                do {
                    try await store.markOpened(activityID: candidate.activityID, sessionKey: session.id, queryAlias: queryAlias)
                    return true
                } catch is CancellationError { throw CancellationError() }
                catch { return false }
            }
            openingTask = task
            openingOwner = owner
            defer {
                if openingOwner == owner {
                    openingTask = nil
                    openingOwner = nil
                }
            }
            let remembered = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard owns(owner) else { return AgentRouterResult(outcome: .cancelled) }
            return AgentRouterResult(outcome: remembered ? .requestedOpen : .openedWithoutContinuation,
                                     activityTitle: candidate.activityTitle, application: session.application)
        } catch is CancellationError {
            return AgentRouterResult(outcome: .cancelled)
        } catch {
            return AgentRouterResult(outcome: owns(owner) ? .failed : .cancelled, activityTitle: candidate.activityTitle, application: candidate.application)
        }
    }

    /// Checks cancellation and request ownership after an asynchronous boundary.
    ///
    /// Args:
    ///   owner: Generation captured before work began.
    ///
    /// Returns:
    ///   Whether this request may still dispatch navigation or publish feedback.
    private func owns(_ owner: Int) -> Bool { generation == owner && !Task.isCancelled }

    /// Owns a pending persistence task so replacement can cancel it before store entry.
    ///
    /// Args:
    ///   requestID: Active picker token.
    ///   operation: Serialized rename or association write.
    ///
    /// Throws:
    ///   Cancellation, stale picker, or store validation/persistence failure.
    private func performEdit(requestID: UUID, operation: @escaping @Sendable () async throws -> Void) async throws {
        guard pendingSelection?.id == requestID else { throw AgentActivityStoreError.unknownActivity }
        editTask?.cancel()
        let taskID = UUID()
        let task = Task { try Task.checkCancellation(); try await operation() }
        editTask = task
        editTaskID = taskID
        defer {
            if editTaskID == taskID {
                editTask = nil
                editTaskID = nil
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard pendingSelection?.id == requestID else { throw AgentActivityStoreError.unknownActivity }
    }
}
