import XCTest
@testable import Type4Me

final class AgentActivityPickerTests: XCTestCase {
    /// Renders unnamed sessions in the current language without altering names or search keys.
    func testUnnamedConversationLabelFollowsLanguageChanges() {
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(AgentSessionDescriptor.displayTitle("", language: language),
                           language == .zh ? "未命名会话" : "Untitled conversation")
            XCTAssertEqual(AgentSessionDescriptor.displayTitle("我的研究", language: language), "我的研究")
            let result = AgentRouterResult(outcome: .matchedPreview, activityTitle: "", application: .codex)
            XCTAssertTrue(result.message(language: language).contains(
                AgentSessionDescriptor.displayTitle("", language: language)
            ))
        }
    }

    /// Verifies persistent picker copy follows language changes without altering user names.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts Chinese, English, then Chinese rendering of the same query.
    func testPickerCopyFollowsLanguageChanges() {
        let query = "论文周报"
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(
                AgentActivityPickerCopy.subtitle(query: query, language: language),
                language == .zh ? "查找“论文周报”" : "Looking for “论文周报”"
            )
            XCTAssertEqual(
                AgentActivityPickerCopy.text(.unavailable, language: language),
                language == .zh ? "暂不支持定位原会话" : "Opening this existing session is not supported yet"
            )
            XCTAssertEqual(
                AgentActivityPickerCopy.text(.renameFailed, language: language),
                language == .zh ? "称呼未保存，请重试。" : "The name was not saved. Try again."
            )
        }
        for label in AgentActivityPickerCopy.Label.allCases {
            XCTAssertFalse(AgentActivityPickerCopy.text(label, language: .zh).isEmpty)
            XCTAssertFalse(AgentActivityPickerCopy.text(label, language: .en).isEmpty)
        }
    }

    /// Verifies query feedback changes language without changing the frozen candidates.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts weak-match and alias-learning copy in Chinese, English, then Chinese.
    func testQueryNoticesFollowLanguageChanges() {
        let candidates = [candidate(
            activityID: UUID(), application: .codex, sessionID: "weak",
            score: AgentFuzzyMatcher.defaultThreshold.nextDown
        )]
        let notices = AgentActivityPickerCopy.notices(query: " 论文周报 ", candidates: candidates)
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(notices.map { AgentActivityPickerCopy.text($0, language: language) }, language == .zh
                ? ["还没确定是哪件事，请从候选中选择。", "打开后会记住这个称呼"]
                : ["The activity isn't confirmed yet. Choose from the candidates.", "This name will be remembered after opening the session"])
        }
        XCTAssertEqual(AgentActivityPickerCopy.segments(candidates).flatMap(\.candidates), candidates)
    }

    /// Verifies confidence notices use the first frozen candidate without sorting it again.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts the threshold is inclusive and stronger later candidates do not reorder rows.
    func testQueryNoticesUseFirstCandidateAndThresholdBoundary() {
        let weak = candidate(
            activityID: UUID(), application: .codex, sessionID: "weak",
            score: AgentFuzzyMatcher.defaultThreshold.nextDown
        )
        let strong = candidate(
            activityID: UUID(), application: .codex, sessionID: "strong",
            score: AgentFuzzyMatcher.defaultThreshold
        )
        let weakFirst = [weak, strong]
        XCTAssertEqual(
            AgentActivityPickerCopy.notices(query: "周报", candidates: weakFirst)
                .map { AgentActivityPickerCopy.text($0, language: .zh) },
            ["还没确定是哪件事，请从候选中选择。", "打开后会记住这个称呼"]
        )
        XCTAssertEqual(
            AgentActivityPickerCopy.notices(query: "周报", candidates: [strong, weak])
                .map { AgentActivityPickerCopy.text($0, language: .zh) },
            ["打开后会记住这个称呼"]
        )
        XCTAssertEqual(AgentActivityPickerCopy.segments(weakFirst).flatMap(\.candidates), weakFirst)
    }

    /// Verifies browsing and an empty result do not promise query-name learning.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts empty and whitespace-only queries show neither query notice.
    func testQueryNoticesAreAbsentWhenBrowsingOrWithoutCandidates() {
        let candidates = [candidate(
            activityID: UUID(), application: .codex, sessionID: "weak", score: 0
        )]
        for query in ["", " \n\t"] {
            XCTAssertTrue(AgentActivityPickerCopy.notices(query: query, candidates: candidates).isEmpty)
        }
        XCTAssertTrue(AgentActivityPickerCopy.notices(query: "周报", candidates: []).isEmpty)
    }

    /// Verifies equal titles remain separate while one activity can hold both providers.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts grouping uses activity identity and preserves candidate order.
    func testGroupsUseStableActivityIdentityRatherThanTitle() {
        let first = UUID()
        let second = UUID()
        let candidates = [
            candidate(activityID: first, application: .codex, sessionID: "shared-id"),
            candidate(activityID: second, application: .codex, sessionID: "another-id"),
            candidate(activityID: first, application: .claudeCode, sessionID: "shared-id"),
        ]
        let groups = AgentActivityPickerCopy.groups(candidates)
        XCTAssertEqual(groups.map(\.id), [first, second])
        XCTAssertEqual(groups.map(\.title), ["同名事情", "同名事情"])
        XCTAssertEqual(groups[0].candidates.map(\.session.id), ["codex:shared-id", "claudeCode:shared-id"])
        XCTAssertEqual(groups[1].candidates.map(\.session.id), ["codex:another-id"])
    }

    /// Verifies repeated activity headers retain ordinal order and association targets stay unique.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts segments flatten to the frozen sequence while targets deduplicate by identity.
    func testContiguousSegmentsPreserveCandidateOrderAndDistinctAssociationTargets() {
        let first = UUID()
        let second = UUID()
        let candidates = [
            candidate(activityID: first, application: .codex, sessionID: "a1"),
            candidate(activityID: second, application: .codex, sessionID: "b1"),
            candidate(activityID: first, application: .codex, sessionID: "a2"),
            candidate(activityID: first, application: .claudeCode, sessionID: "a3"),
        ]
        let segments = AgentActivityPickerCopy.segments(candidates)
        XCTAssertEqual(segments.map(\.id), [first, second, first])
        XCTAssertEqual(segments.flatMap(\.candidates), candidates)
        XCTAssertEqual(segments.map { $0.candidates.count }, [1, 1, 2])
        let targets = AgentActivityPickerCopy.groups(candidates)
        XCTAssertEqual(targets.map(\.id), [first, second])
        XCTAssertEqual(Set(targets.map(\.id)).count, targets.count)
        XCTAssertEqual(targets.filter { $0.id != first }.map(\.id), [second])
    }

    /// Verifies an explicit association retains ordinal order even when it splits an activity.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts post-link display retains the frozen session sequence.
    func testLinkedCandidatesDoNotRegroupOrReorderDisplayedRows() {
        let first = UUID()
        let second = UUID()
        let candidates = [
            candidate(activityID: first, application: .codex, sessionID: "a1"),
            candidate(activityID: first, application: .codex, sessionID: "a2"),
            candidate(activityID: first, application: .codex, sessionID: "a3"),
            candidate(activityID: second, application: .codex, sessionID: "b1"),
        ]
        let linked = AgentActivityPickerCopy.linkedCandidates(
            sessionKey: "codex:a2", activityID: second, title: "另一件事", candidates: candidates
        )
        let segments = AgentActivityPickerCopy.segments(linked)
        XCTAssertEqual(segments.map(\.id), [first, second, first, second])
        XCTAssertEqual(segments.flatMap(\.candidates), linked)
        XCTAssertEqual(segments.flatMap(\.candidates).map(\.session.id), candidates.map(\.session.id))
        XCTAssertEqual(AgentActivityPickerCopy.groups(linked).map(\.id), [first, second])
    }

    /// Verifies update timestamps render from the same date when the language changes.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts Chinese, English, then Chinese formatting without cached copy.
    func testTimestampFormatFollowsLanguageChanges() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let chinese = date.formatted(AgentActivityPickerCopy.timestampFormat(language: .zh))
        let english = date.formatted(AgentActivityPickerCopy.timestampFormat(language: .en))
        XCTAssertNotEqual(chinese, english)
        XCTAssertEqual(date.formatted(AgentActivityPickerCopy.timestampFormat(language: .zh)), chinese)
        XCTAssertEqual(AgentActivityPickerCopy.timestampFormat(language: .zh).locale.identifier, "zh_CN")
        XCTAssertEqual(AgentActivityPickerCopy.timestampFormat(language: .en).locale.identifier, "en_US")
    }

    /// Verifies names and associations update the selected candidate without reordering it.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts explicit linking changes only one provider-qualified session.
    func testRenameAndLinkPreserveConcreteSessionIdentity() {
        let source = UUID()
        let target = UUID()
        let original = [
            candidate(activityID: source, application: .codex, sessionID: "same-id"),
            candidate(activityID: source, application: .claudeCode, sessionID: "same-id"),
            candidate(activityID: target, application: .codex, sessionID: "target-id"),
        ]
        let renamed = AgentActivityPickerCopy.renamedCandidates(
            activityID: source, title: "论文", candidates: original
        )
        XCTAssertEqual(renamed.map(\.id), original.map(\.id))
        XCTAssertEqual(renamed.map(\.activityTitle), ["论文", "论文", "同名事情"])
        let linked = AgentActivityPickerCopy.linkedCandidates(
            sessionKey: "codex:same-id", activityID: target, title: "周报", candidates: renamed
        )
        XCTAssertEqual(linked.map(\.session.id), original.map(\.session.id))
        XCTAssertEqual(linked[0].activityID, target)
        XCTAssertEqual(linked[0].activityTitle, "周报")
        XCTAssertEqual(linked[1], renamed[1])
        XCTAssertFalse(linked[1].canOpen)
    }

    /// Verifies a name is semantic user text rather than an empty or localized UI label.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts blank rejection and preservation of meaningful Unicode names.
    func testNameNormalizationPreservesUserText() {
        XCTAssertNil(AgentActivityPickerCopy.normalizedName(" \n\t"))
        XCTAssertEqual(AgentActivityPickerCopy.normalizedName("  我的论文 / Paper \n"), "我的论文 / Paper")
    }

    /// Verifies replacing a picker completes the old request and ignores its stale callback.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Uses a mocked presenter and never creates a panel or sends an agent message.
    @MainActor
    func testReplacementAndStaleCancelCompleteExactlyOnce() async throws {
        let firstPresented = expectation(description: "first mock picker")
        let secondPresented = expectation(description: "second mock picker")
        var presentationCount = 0
        var dismissalCount = 0
        var oldCancel: (() -> Void)?
        var currentSelect: ((String) -> Void)?
        let controller = AgentActivityPickerPanelController(present: { state in
            presentationCount += 1
            if presentationCount == 1 {
                oldCancel = state.onCancel
                firstPresented.fulfill()
            } else {
                currentSelect = state.onSelect
                secondPresented.fulfill()
            }
        }, dismiss: { dismissalCount += 1 })
        let firstCandidate = candidate(activityID: UUID(), application: .codex, sessionID: "first")
        let secondCandidate = candidate(activityID: UUID(), application: .codex, sessionID: "second")
        let firstTask = Task { @MainActor in
            await controller.choose(query: "first", candidates: [firstCandidate], onRename: { _, _ in }, onLink: { _, _ in })
        }
        await fulfillment(of: [firstPresented], timeout: 1)
        let secondTask = Task { @MainActor in
            await controller.choose(query: "second", candidates: [secondCandidate], onRename: { _, _ in }, onLink: { _, _ in })
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
            controller.hide()
        }
        await fulfillment(of: [secondPresented], timeout: 1)
        let firstResult = await firstTask.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(dismissalCount, 1)
        oldCancel?()
        XCTAssertEqual(dismissalCount, 1)
        let select = try XCTUnwrap(currentSelect)
        select(secondCandidate.session.id)
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, secondCandidate)
        XCTAssertEqual(dismissalCount, 2)
        controller.hide()
        XCTAssertEqual(dismissalCount, 2)
    }

    /// Verifies a cancelled task does not create its picker when it has not begun.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts cancellation completes without presentation or UI interaction.
    @MainActor
    func testCancellationBeforePresentationDoesNotShowPicker() async {
        var presentationCount = 0
        let controller = AgentActivityPickerPanelController(present: { _ in presentationCount += 1 })
        let task = Task { @MainActor in
            await controller.choose(query: "", candidates: [], onRename: { _, _ in }, onLink: { _, _ in })
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(presentationCount, 0)
    }

    /// Builds metadata-only mock candidates without accessing the user's agent files.
    ///
    /// Args:
    ///   activityID: Stable synthetic activity identity.
    ///   application: Provider represented by the mocked session.
    ///   sessionID: Provider-local identifier, allowing same IDs across providers.
    ///   score: Synthetic match confidence, defaulting to an exact match.
    ///
    /// Returns:
    ///   A candidate whose opening capability matches its synthetic provider.
    private func candidate(
        activityID: UUID, application: AgentDesktopApplication, sessionID: String, score: Double = 1
    ) -> AgentActivityCandidate {
        AgentActivityCandidate(
            activityID: activityID, activityTitle: "同名事情",
            session: AgentSessionDescriptor(
                sessionID: sessionID, application: application, title: "同题会话",
                workspacePath: "/synthetic-workspace", updatedAt: 1, matchTexts: ["同题会话"],
                openCapability: application == .codex ? .codexDeepLink : .unsupported
            ),
            score: score
        )
    }
}
