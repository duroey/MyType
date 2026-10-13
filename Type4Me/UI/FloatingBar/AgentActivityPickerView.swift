import SwiftUI

enum AgentActivityPickerLayout {
    static let preferredWidth: CGFloat = 620
    static let preferredHeight: CGFloat = 540
    static let screenInset: CGFloat = 24
    static let floatingBarGap: CGFloat = 18
    static let cornerRadius: CGFloat = 18
    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]
    static let digitShortcuts = 1...9
}

struct AgentActivityPickerGroup: Identifiable {
    let id: UUID
    let title: String
    var candidates: [AgentActivityCandidate]
}

enum AgentActivityPickerCopy {
    enum Label: CaseIterable {
        case title, cancel, rename, namePlaceholder, save, saving, shortcuts, updated
        case unavailable, emptyTitle, emptyDetail, renameFailed, linkFailed, missingName, invalidName, staleActivity, link
        case weakMatch, rememberName
        case historyEvidence, evidenceTime, historyReview
    }

    /// Renders interface copy without translating user-supplied activity or session names.
    ///
    /// Args:
    ///   label: Semantic label displayed by the persistent picker.
    ///   language: Current interface language observed by the view.
    ///
    /// Returns:
    ///   Chinese or English copy for the requested label.
    nonisolated static func text(_ label: Label, language: AppLanguage) -> String {
        let copy: (String, String)
        switch label {
        case .title: copy = ("选择会话", "Choose a session")
        case .cancel: copy = ("取消", "Cancel")
        case .rename: copy = ("改称呼", "Rename")
        case .namePlaceholder: copy = ("给这件事情起个称呼", "Give this activity a familiar name")
        case .save: copy = ("保存", "Save")
        case .saving: copy = ("保存中…", "Saving…")
        case .shortcuts: copy = ("按 1–9 选择，Return 打开，Esc 取消", "Choose with 1–9, Return to open, Esc to cancel")
        case .updated: copy = ("更新于", "Updated")
        case .unavailable: copy = ("暂不支持定位原会话", "Opening this existing session is not supported yet")
        case .emptyTitle: copy = ("没有找到事项", "No activities found")
        case .emptyDetail: copy = ("先在桌面 Agent 中创建会话，再打开此列表。", "Create a session in a desktop agent, then open this list again.")
        case .renameFailed: copy = ("称呼未保存，请重试。", "The name was not saved. Try again.")
        case .linkFailed: copy = ("会话未能关联，请重试。", "The session could not be linked. Try again.")
        case .missingName: copy = ("请填写事项称呼。", "Enter a name for the activity.")
        case .invalidName: copy = ("请使用较短的非空称呼。", "Use a shorter, nonempty name.")
        case .staleActivity: copy = ("事项或会话归属已变化，请重新打开列表。", "The activity or session association changed. Open the list again.")
        case .link: copy = ("关联到其他事情", "Link to another activity")
        case .weakMatch: copy = ("还没确定是哪件事，请从候选中选择。", "The activity isn't confirmed yet. Choose from the candidates.")
        case .rememberName: copy = ("打开后会记住这个称呼", "This name will be remembered after opening the session")
        case .historyEvidence: copy = ("历史内容", "History excerpt")
        case .evidenceTime: copy = ("消息时间", "Message time")
        case .historyReview: copy = ("请核对历史内容，选择要继续的会话。", "Review the history excerpts and choose the conversation to continue.")
        }
        return language == .zh ? copy.0 : copy.1
    }

    /// Describes the current search while preserving the spoken query verbatim.
    ///
    /// Args:
    ///   query: Spoken activity name, or an empty string when browsing all activities.
    ///   language: Current interface language.
    ///
    /// Returns:
    ///   A localized subtitle for the picker.
    nonisolated static func subtitle(query: String, language: AppLanguage) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return language == .zh
                ? "查看事情，选择会话或设置称呼"
                : "Browse activities, choose a session, or set a familiar name"
        }
        return language == .zh ? "查找“\(query)”" : "Looking for “\(query)”"
    }

    /// Chooses semantic query notices without changing the frozen candidate order.
    ///
    /// Args:
    ///   query: Spoken activity name, or an empty string when browsing.
    ///   candidates: Frozen candidates in the order supplied by the router.
    ///
    /// Returns:
    ///   A weak-match notice below the shared threshold and a query-name learning hint.
    ///   Browsing or an empty result shows neither notice.
    nonisolated static func notices(query: String, candidates: [AgentActivityCandidate]) -> [Label] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = candidates.first else { return [] }
        if candidates.contains(where: { $0.evidence != nil }) { return [.historyReview, .rememberName] }
        return first.score < AgentFuzzyMatcher.defaultThreshold
            ? [.weakMatch, .rememberName]
            : [.rememberName]
    }

    /// Renders an excerpt as plain work evidence without embedded file links or formatting.
    ///
    /// Args:
    ///   evidence: Transient historical message supplied by the search backend.
    ///
    /// Returns:
    ///   Readable text; this transformation is never used for ranking or identity mapping.
    nonisolated static func excerpt(_ evidence: AgentActivityEvidence) -> String {
        evidence.snippet
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\n)]*(?:\)|$)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Groups candidates by stable activity identity for distinct association targets.
    ///
    /// Args:
    ///   candidates: Frozen session candidates supplied by the router.
    ///
    /// Returns:
    ///   Distinct activity groups in first-seen order; equal titles never merge identities.
    nonisolated static func groups(_ candidates: [AgentActivityCandidate]) -> [AgentActivityPickerGroup] {
        var groups: [AgentActivityPickerGroup] = []
        var groupIndexes: [UUID: Int] = [:]
        for candidate in candidates {
            if let index = groupIndexes[candidate.activityID] {
                groups[index].candidates.append(candidate)
            } else {
                groupIndexes[candidate.activityID] = groups.count
                groups.append(AgentActivityPickerGroup(
                    id: candidate.activityID, title: candidate.activityTitle, candidates: [candidate]
                ))
            }
        }
        return groups
    }

    /// Splits the frozen candidates into contiguous activity segments without reordering them.
    ///
    /// Args:
    ///   candidates: Frozen session candidates, including recently linked sessions.
    ///
    /// Returns:
    ///   Contiguous segments whose flattened candidates retain the exact input order.
    ///   A repeated activity may have several headers sharing its activity identity.
    nonisolated static func segments(_ candidates: [AgentActivityCandidate]) -> [AgentActivityPickerGroup] {
        var segments: [AgentActivityPickerGroup] = []
        for candidate in candidates {
            if segments.last?.id == candidate.activityID {
                segments[segments.count - 1].candidates.append(candidate)
            } else {
                segments.append(AgentActivityPickerGroup(
                    id: candidate.activityID, title: candidate.activityTitle, candidates: [candidate]
                ))
            }
        }
        return segments
    }

    /// Builds a date format from the language observed by the persistent picker.
    ///
    /// Args:
    ///   language: Current interface language.
    ///
    /// Returns:
    ///   A localized date and time style for distinguishing otherwise equal session titles.
    nonisolated static func timestampFormat(language: AppLanguage) -> Date.FormatStyle {
        Date.FormatStyle()
            .year().month(.abbreviated).day().hour().minute().second()
            .locale(Locale(identifier: language == .zh ? "zh_CN" : "en_US"))
    }

    /// Trims an edited activity name before requesting persistence.
    ///
    /// Args:
    ///   draft: User-entered name, including any surrounding whitespace.
    ///
    /// Returns:
    ///   A nonempty semantic name, or nil when the draft is blank.
    nonisolated static func normalizedName(_ draft: String) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Updates one activity name without changing session identities or candidate order.
    ///
    /// Args:
    ///   activityID: Activity whose name was persisted.
    ///   title: Saved user-facing name.
    ///   candidates: Current candidate snapshot.
    ///
    /// Returns:
    ///   Candidates with the saved activity name applied to all associated sessions.
    nonisolated static func renamedCandidates(
        activityID: UUID, title: String, candidates: [AgentActivityCandidate]
    ) -> [AgentActivityCandidate] {
        candidates.map { candidate in
            AgentActivityCandidate(
                activityID: candidate.activityID,
                activityTitle: candidate.activityID == activityID ? title : candidate.activityTitle,
                session: candidate.session, score: candidate.score, evidence: candidate.evidence
            )
        }
    }

    /// Moves a provider-qualified session without merging similarly titled activities.
    ///
    /// Args:
    ///   sessionKey: Stable provider-qualified session identity.
    ///   activityID: Explicitly selected destination activity.
    ///   title: Destination's current user-facing name.
    ///   candidates: Current candidate snapshot.
    ///
    /// Returns:
    ///   Candidates with only the explicitly chosen session associated to the target.
    nonisolated static func linkedCandidates(
        sessionKey: String, activityID: UUID, title: String, candidates: [AgentActivityCandidate]
    ) -> [AgentActivityCandidate] {
        candidates.map { candidate in
            guard candidate.session.id == sessionKey else { return candidate }
            return AgentActivityCandidate(
                activityID: activityID, activityTitle: title,
                session: candidate.session, score: candidate.score, evidence: candidate.evidence
            )
        }
    }

    /// Maps persistence failures to semantic inline feedback without exposing file paths.
    ///
    /// Args:
    ///   error: Failure returned by activity name or association persistence.
    ///   fallback: Generic operation-specific label for other failures.
    ///
    /// Returns:
    ///   A semantic error label rendered by the currently observed UI language.
    nonisolated static func errorLabel(_ error: Error, fallback: Label) -> Label {
        guard let error = error as? AgentActivityStoreError else { return fallback }
        switch error {
        case .invalidTitle: return .invalidName
        case .unknownActivity, .unknownSession: return .staleActivity
        default: return fallback
        }
    }
}

@MainActor
final class AgentActivityPickerState: ObservableObject {
    @Published var query = ""
    @Published var candidates: [AgentActivityCandidate] = []
    @Published var editingActivityID: UUID?
    @Published var nameDraft = ""
    @Published var isUpdating = false
    @Published var error: AgentActivityPickerCopy.Label?
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onLink: ((String, UUID) -> Void)?
}

struct AgentActivityPickerView: View {
    @ObservedObject var state: AgentActivityPickerState
    @AppStorage("tf_language") private var languageRaw = AppLanguage.systemDefault
    @AppStorage(RecordingTheme.storageKey) private var theme = RecordingTheme.defaultValue
    @FocusState private var isNameFocused: Bool
    @State private var editingSegmentIndex: Int?

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .en }
    private var textColor: Color { theme == .light ? TF.floatingTextLight : TF.floatingText }
    private var groups: [AgentActivityPickerGroup] { AgentActivityPickerCopy.groups(state.candidates) }
    private var segments: [AgentActivityPickerGroup] { AgentActivityPickerCopy.segments(state.candidates) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(copy(.title))
                    .font(.system(size: 20, weight: .semibold))
                Text(AgentActivityPickerCopy.subtitle(query: state.query, language: language))
                    .font(.system(size: 12))
                    .foregroundStyle(textColor.opacity(0.65))
                    .lineLimit(2)
                ForEach(
                    Array(AgentActivityPickerCopy.notices(query: state.query, candidates: state.candidates).enumerated()),
                    id: \.offset
                ) { _, notice in
                    Text(copy(notice))
                        .font(.system(size: 12))
                        .foregroundStyle(textColor.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if segments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(textColor.opacity(0.5))
                    Text(copy(.emptyTitle)).font(.system(size: 15, weight: .medium))
                    Text(copy(.emptyDetail))
                        .font(.system(size: 12))
                        .foregroundStyle(textColor.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, group in
                            activityGroup(group, segmentIndex: segmentIndex)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 12) {
                if let error = state.error {
                    Text(copy(error))
                        .font(.system(size: 12))
                        .foregroundStyle(textColor.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                } else if !state.candidates.isEmpty, state.editingActivityID == nil {
                    Text(copy(.shortcuts))
                        .font(.system(size: 10))
                        .foregroundStyle(textColor.opacity(0.55))
                }
                Spacer(minLength: 0)
                Button(copy(.cancel)) { state.onCancel?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AgentActivityPickerLayout.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AgentActivityPickerLayout.cornerRadius)
                .strokeBorder(textColor.opacity(0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, theme == .light ? .light : .dark)
        .onChange(of: state.editingActivityID) { _, id in
            isNameFocused = id != nil
            if id == nil { editingSegmentIndex = nil }
        }
    }

    /// Builds an activity header, optional name editor, and its concrete sessions.
    ///
    /// Args:
    ///   group: Sessions sharing one stable activity identity.
    ///   segmentIndex: Presentation identity of this contiguous segment, independent of activity identity.
    ///
    /// Returns:
    ///   A title-led group without filesystem paths or directory controls.
    @ViewBuilder
    private func activityGroup(_ group: AgentActivityPickerGroup, segmentIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(AgentSessionDescriptor.displayTitle(group.title, language: language))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(copy(.rename)) { beginRename(group, segmentIndex: segmentIndex) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(textColor.opacity(0.65))
                    .disabled(state.isUpdating)
            }
            if state.editingActivityID == group.id, editingSegmentIndex == segmentIndex {
                HStack(spacing: 8) {
                    TextField(copy(.namePlaceholder), text: $state.nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onSubmit { state.onRename?(group.id, state.nameDraft) }
                        .disabled(state.isUpdating)
                    Button(copy(state.isUpdating ? .saving : .save)) {
                        state.onRename?(group.id, state.nameDraft)
                    }
                    .disabled(state.isUpdating)
                    Button(copy(.cancel)) {
                        state.editingActivityID = nil
                        state.error = nil
                    }
                    .disabled(state.isUpdating)
                }
            }
            ForEach(group.candidates) { candidate in
                sessionRow(candidate)
            }
        }
    }

    /// Builds a concrete session choice with a secondary provider badge.
    ///
    /// Args:
    ///   candidate: Session candidate within the currently displayed activity.
    ///
    /// Returns:
    ///   A selectable row, or a disabled row explaining unavailable session opening.
    private func sessionRow(_ candidate: AgentActivityCandidate) -> some View {
        let number = state.candidates.firstIndex { $0.session.id == candidate.session.id }.map { $0 + 1 }
        return VStack(spacing: 0) {
            Button { state.onSelect?(candidate.session.id) } label: {
                HStack(spacing: 12) {
                    if let number {
                        Text(String(number))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(textColor.opacity(0.6))
                            .frame(width: 18)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AgentSessionDescriptor.displayTitle(candidate.sessionTitle, language: language))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 4) {
                            Text(copy(.updated))
                            Text(
                                Date(timeIntervalSince1970: candidate.session.updatedAt),
                                format: AgentActivityPickerCopy.timestampFormat(language: language)
                            )
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(textColor.opacity(0.6))
                        if let evidence = candidate.evidence {
                            Text(copy(.historyEvidence))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(textColor.opacity(0.6))
                            Text(AgentActivityPickerCopy.excerpt(evidence))
                                .font(.system(size: 12))
                                .foregroundStyle(textColor.opacity(0.85))
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                            if let timestamp = evidence.timestamp {
                                HStack(spacing: 4) {
                                    Text(copy(.evidenceTime))
                                    Text(timestamp, format: AgentActivityPickerCopy.timestampFormat(language: language))
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(textColor.opacity(0.6))
                            }
                        }
                        if !candidate.canOpen {
                            Text(copy(.unavailable))
                                .font(.system(size: 11))
                                .foregroundStyle(textColor.opacity(0.65))
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(candidate.application.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.65))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(textColor.opacity(0.06), in: Capsule())
                    if candidate.canOpen {
                        if state.candidates.first(where: \.canOpen)?.session.id == candidate.session.id {
                            Text("↩")
                                .font(.system(size: 12))
                                .foregroundStyle(textColor.opacity(0.5))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(textColor.opacity(0.5))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(textColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(!candidate.canOpen || state.isUpdating)
        }
        .contextMenu {
            Menu(copy(.link)) {
                ForEach(groups.filter { $0.id != candidate.activityID }) { target in
                    Button(AgentSessionDescriptor.displayTitle(target.title, language: language)) {
                        state.onLink?(candidate.session.id, target.id)
                    }
                        .disabled(state.isUpdating)
                }
            }
            .disabled(groups.count < 2 || state.isUpdating)
        }
    }

    /// Opens the inline name editor for a specific activity.
    ///
    /// Args:
    ///   group: Activity whose user-facing name will be edited.
    ///   segmentIndex: Header that owns the single inline editor for this activity.
    ///
    /// Returns:
    ///   Nothing. Preserves the current title as the editable draft.
    private func beginRename(_ group: AgentActivityPickerGroup, segmentIndex: Int) {
        editingSegmentIndex = segmentIndex
        state.editingActivityID = group.id
        state.nameDraft = group.title
        state.error = nil
        isNameFocused = true
    }

    /// Renders one semantic label from the observed language setting.
    ///
    /// Args:
    ///   label: Label currently displayed in the persistent picker.
    ///
    /// Returns:
    ///   Localized text that changes without recreating the panel.
    private func copy(_ label: AgentActivityPickerCopy.Label) -> String {
        AgentActivityPickerCopy.text(label, language: language)
    }
}
