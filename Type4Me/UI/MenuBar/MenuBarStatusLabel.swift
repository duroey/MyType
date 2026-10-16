import SwiftUI

/// Shows actionable inbox messages in the menu bar without counting active workers.
struct MenuBarStatusLabel: View {
    let appState: AppState
    @ObservedObject var inbox: AgentInboxStore
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    private let maximumDisplayedCount = 99

    private var attentionCount: Int {
        inbox.items.lazy.filter(\.needsAttention).count
    }

    var body: some View {
        if appState.quietCalibrationSecondsRemaining > 0 {
            Text(L("安静 \(appState.quietCalibrationSecondsRemaining)秒",
                   "Quiet \(appState.quietCalibrationSecondsRemaining)s"))
        } else if attentionCount > 0 {
            Text(attentionCount > maximumDisplayedCount ? "\(maximumDisplayedCount)+" : String(attentionCount))
                .monospacedDigit()
                .fontWeight(.semibold)
                .accessibilityLabel(L("MyType：\(attentionCount) 条 Agent 消息待处理",
                                      "MyType: Agent messages needing attention: \(attentionCount)"))
        } else {
            Image(systemName: appState.barPhase == .hidden ? "mic" : "mic.fill")
                .accessibilityLabel("MyType")
        }
    }
}
