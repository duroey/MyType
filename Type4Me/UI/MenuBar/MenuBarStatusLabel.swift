import SwiftUI

/// Shows active and actionable Agent sessions together in a compact menu bar label.
struct MenuBarStatusLabel: View {
    let appState: AppState
    @ObservedObject var inbox: AgentInboxStore
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    private let maximumDisplayedCount = 99

    private var agentCount: Int {
        inbox.items.lazy.filter {
            $0.status == .running || $0.status == .waiting || $0.needsAttention
        }.count
    }

    var body: some View {
        if appState.quietCalibrationSecondsRemaining > 0 {
            Text(L("安静 \(appState.quietCalibrationSecondsRemaining)秒",
                   "Quiet \(appState.quietCalibrationSecondsRemaining)s"))
        } else if agentCount > 0 {
            Label {
                Text(agentCount > maximumDisplayedCount ? "\(maximumDisplayedCount)+" : String(agentCount))
                    .monospacedDigit()
            } icon: {
                Image(systemName: appState.barPhase == .recording ? "mic.fill" : "square.stack")
                    .symbolRenderingMode(.monochrome)
            }
            .labelStyle(.titleAndIcon)
            .font(.system(.callout, weight: .medium))
            .accessibilityLabel(L("MyType：\(agentCount) 个 Agent 正在工作或待处理",
                                  "MyType: \(agentCount) Agents working or needing attention"))
        } else {
            Image(systemName: appState.barPhase == .hidden ? "mic" : "mic.fill")
                .accessibilityLabel("MyType")
        }
    }
}
