import XCTest
@testable import Type4Me

final class AgentLauncherSettingsTests: XCTestCase {
    /// Verifies the same status snapshot renders Chinese, English, then Chinese.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts both apps appear without a global provider choice.
    func testInstallationSummaryFollowsLanguageChanges() {
        let snapshot = Array(installations(installed: AgentDesktopApplication.allCases).reversed())
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(
                GeneralSettingsTab.launcherInstallationSummary(language: language, installations: snapshot),
                language == .zh ? "已安装：Codex、Claude Code" : "Installed: Codex, Claude Code"
            )
        }
    }

    /// Verifies installation changes update informational status in both languages.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts removed apps are absent rather than retained as selections.
    func testInstallationSummaryReflectsRemovedApplication() {
        let snapshot = installations(installed: [.claudeCode])
        XCTAssertEqual(
            GeneralSettingsTab.launcherInstallationSummary(language: .zh, installations: snapshot),
            "已安装：Claude Code"
        )
        XCTAssertEqual(
            GeneralSettingsTab.launcherInstallationSummary(language: .en, installations: snapshot),
            "Installed: Claude Code"
        )
    }

    /// Verifies no installed app produces actionable refresh guidance in both languages.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts language-sensitive empty installation guidance.
    func testMissingApplicationsShowRefreshGuidance() {
        let snapshot = installations(installed: [])
        XCTAssertEqual(
            GeneralSettingsTab.launcherInstallationSummary(language: .zh, installations: snapshot),
            "尚未检测到 Codex 或 Claude Code。安装桌面应用后点击刷新。"
        )
        XCTAssertEqual(
            GeneralSettingsTab.launcherInstallationSummary(language: .en, installations: snapshot),
            "Codex and Claude Code were not found. Install a desktop app, then refresh."
        )
    }

    /// Verifies previous built-in router descriptions follow the new activity wording.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts language switching while preserving a custom description.
    func testEarlierRouterDescriptionsLocalizeWithoutChangingCustomCopy() {
        var mode = ProcessingMode.agentRouterMode
        for previous in [
            "呼出 Agent 路由并启动对应工作目录",
            "Open Agent Router and launch the matching workspace",
            "根据口述项目名打开所选桌面 Agent",
            "Open the selected desktop agent for a spoken project name",
        ] {
            mode.description = previous
            XCTAssertEqual(mode.localizedDisplayDescription(for: .zh), "找回 Agent 会话或交接工作")
            XCTAssertEqual(mode.localizedDisplayDescription(for: .en), "Find agent conversations or hand off work")
        }
        mode.description = "My own activity workflow"
        XCTAssertEqual(mode.localizedDisplayDescription(for: .zh), "My own activity workflow")
        XCTAssertEqual(mode.localizedDisplayDescription(for: .en), "My own activity workflow")
    }

    /// Builds a synthetic installation snapshot without consulting the computer.
    ///
    /// Args:
    ///   installed: Applications represented as installed by this fixture.
    ///
    /// Returns:
    ///   One mocked installation per supported application.
    private func installations(installed: [AgentDesktopApplication]) -> [AgentDesktopInstallation] {
        AgentDesktopApplication.allCases.map { application in
            AgentDesktopInstallation(
                application: application,
                applicationURL: installed.contains(application)
                    ? URL(fileURLWithPath: "/test-apps/\(application.rawValue).app") : nil,
                commandURL: nil
            )
        }
    }
}
