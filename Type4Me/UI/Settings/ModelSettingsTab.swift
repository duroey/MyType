import SwiftUI

struct ModelSettingsTab: View, SettingsCardHelpers {

    var showsHeader = true
    let draftCoordinator: SettingsDraftCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                SettingsSectionHeader(
                    label: L("模型", "MODELS"),
                    title: L("模型配置", "Model Configuration"),
                    description: L("语音识别与文本处理引擎配置。", "ASR and LLM engine configuration.")
                )
            }

            ASRSettingsCard(draftCoordinator: draftCoordinator)

            Spacer().frame(height: 16)

            LLMSettingsCard(draftCoordinator: draftCoordinator)
        }
    }
}
