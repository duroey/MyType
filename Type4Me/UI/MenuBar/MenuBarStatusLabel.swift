import SwiftUI

/// Shows active and actionable Agent sessions together in a compact menu bar label.
struct MenuBarStatusLabel: View {
    let appState: AppState
    @ObservedObject var inbox: AgentInboxStore
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        let summary = AgentInboxSummary(items: inbox.items)
        let currentLanguage = AppLanguage(rawValue: language) ?? .en
        if appState.quietCalibrationSecondsRemaining > 0 {
            Text(L("安静 \(appState.quietCalibrationSecondsRemaining)秒",
                   "Quiet \(appState.quietCalibrationSecondsRemaining)s"))
        } else if summary.count > 0 {
            Label {
                Text(summary.countText).monospacedDigit()
            } icon: {
                if appState.barPhase == .recording {
                    Image(systemName: "mic.fill").symbolRenderingMode(.monochrome)
                } else {
                    Image(nsImage: AgentInboxIdentity.symbol).renderingMode(.template)
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.system(.callout, weight: .medium))
            .accessibilityLabel(summary.accessibilityLabel(language: currentLanguage))
            .help(summary.accessibilityLabel(language: currentLanguage))
        } else {
            Image(systemName: appState.barPhase == .hidden ? "mic" : "mic.fill")
                .accessibilityLabel("MyType")
        }
    }
}
