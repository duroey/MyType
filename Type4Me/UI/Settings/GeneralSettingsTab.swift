import SwiftUI
import ServiceManagement
import AVFoundation
import ApplicationServices

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - General Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct GeneralSettingsTab: View, SettingsCardHelpers {

    @Environment(AppState.self) private var appState

    // MARK: - Global

    @AppStorage("tf_startSound") private var startSound = StartSoundStyle.chime.rawValue
    @AppStorage("tf_launchAtLogin") private var launchAtLogin = true
    @AppStorage("tf_volumeReduction") private var volumeReduction = -1
    @AppStorage("tf_visualStyle") private var visualStyle = "timeline"
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage("tf_preserveClipboard") private var preserveClipboard = true
    @AppStorage("tf_showDockIcon") private var showDockIcon = true
    @AppStorage("tf_bypassProxy") private var bypassProxy = "off"
    @AppStorage("tf_stripTrailingPunctuation") private var stripTrailingPunctuation = "off"
    @AppStorage("tf_hoverTranscriptPreview") private var hoverTranscriptPreview = true
    @AppStorage("tf_micKeepAlive") private var micKeepAlive = false
    @AppStorage("tf_focusWakeupEnabled") private var focusWakeupEnabled = true
    @AppStorage("tf_focusAutoStopSilenceSeconds") private var focusAutoStopSilenceSeconds = 0.9
    @AppStorage("tf_agentLauncherTerminal") private var agentLauncherTerminal = "auto"
    @AppStorage("tf_selectedMicrophoneUID") private var selectedMicrophoneUID = ""
    @AppStorage("tf_selectedSpeakerUID") private var selectedSpeakerUID = ""

    @State private var hasMic = false
    @State private var hasAccessibility = false
    @State private var availableMicrophones: [(uid: String, name: String)] = []
    @State private var availableSpeakers: [(uid: String, name: String)] = []
    @State private var isCalibratingNoise = false
    @State private var noiseCalibrationStatus = ""
    @State private var launcherModes: [ProcessingMode] = ModeStorage().load()
    @State private var launcherHotkeyRecordingTarget: RecordingTarget?
    @State private var availableLauncherTerminals: [AgentLauncherTerminal] = []

    typealias TestStatus = SettingsTestStatus

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "GENERAL",
                title: L("通用设置", "General Settings"),
                description: L("偏好设置与系统权限。快捷键请在「处理模式」中配置。", "Preferences and permissions. Hotkeys are configured in Modes.")
            )

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音设置", "Recording"), icon: "mic.fill") {
                // Row 1: 麦克风 / 降低音量
                HStack(alignment: .top, spacing: 16) {
                    microphoneSelectionRow
                        .frame(maxWidth: .infinity)
                    volumeReductionRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 录音动效 / 麦克风保活
                HStack(alignment: .top, spacing: 16) {
                    visualStyleRow
                        .frame(maxWidth: .infinity)
                    micKeepAliveRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 3: 自动聚焦 / 底噪校准
                HStack(alignment: .top, spacing: 16) {
                    focusWakeupRow
                        .frame(maxWidth: .infinity)
                    noiseCalibrationRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 4: 自动提交延迟
                HStack(alignment: .top, spacing: 16) {
                    autoStopSilenceRow
                        .frame(maxWidth: .infinity)
                    Spacer()
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 2: 语音识别设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("语音识别设置", "Speech Recognition"), icon: "waveform") {
                // Row 1: 提示音 / 提示音输出
                HStack(alignment: .top, spacing: 16) {
                    startSoundRow
                        .frame(maxWidth: .infinity)
                    speakerSelectionRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 去句末标点 / 悬停文字预览
                HStack(alignment: .top, spacing: 16) {
                    stripPunctuationRow
                        .frame(maxWidth: .infinity)
                    hoverPreviewRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 2: 系统集成
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("系统集成", "System Integration"), icon: "gearshape.2") {
                // Row 1: 开机启动 / Dock图标
                HStack(alignment: .top, spacing: 16) {
                    launchAtLoginRow
                        .frame(maxWidth: .infinity)
                    dockIconRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 剪贴板 / 界面语言
                HStack(alignment: .top, spacing: 16) {
                    preserveClipboardRow
                        .frame(maxWidth: .infinity)
                    languageRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 3: Agent 启动器
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("Agent 启动器", "Agent Launcher"), icon: "terminal.fill") {
                HStack(alignment: .top, spacing: 16) {
                    launcherHotkeyRow
                        .frame(maxWidth: .infinity)
                    launcherTerminalRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 4: 系统权限
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(
                L("系统权限", "Permissions"),
                icon: "lock.shield.fill",
                trailing: AnyView(
                    Button {
                        checkPermissions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("刷新权限状态", "Refresh permission status"))
                )
            ) {
                HStack(spacing: 12) {
                    permissionBlock(
                        icon: "mic.fill", name: L("麦克风", "Microphone"), granted: hasMic
                    ) {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in
                                hasMic = granted
                                if !granted {
                                    NSWorkspace.shared.open(
                                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                                    )
                                }
                            }
                        }
                    }

                    permissionBlock(
                        icon: "accessibility", name: L("辅助功能", "Accessibility"), granted: hasAccessibility
                    ) {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        hasAccessibility = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 5: 高级设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("高级设置", "Advanced"), icon: "wrench.and.screwdriver") {
                // 绕过系统代理
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("绕过系统代理", "Bypass System Proxy").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(TF.settingsTextTertiary)
                    settingsDropdown(
                        selection: $bypassProxy,
                        options: [
                            ("off", L("关闭", "Off")),
                            ("all", L("全局绕过", "All Connections")),
                            ("asr", L("语音识别绕过", "ASR Only")),
                            ("llm", L("文本处理 LLM 绕过", "LLM Only")),
                        ]
                    )
                    Text(L("不经过代理软件，直连对应服务器", "Connect directly to servers, bypassing proxy"))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .padding(.vertical, 6)
            }

        }
        .task {
            checkPermissions()
            syncLoginItemState()
            refreshMicrophones()
            refreshSpeakers()
            reloadLauncherModes()
            refreshLauncherTerminals()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            setLoginItem(enabled: newValue)
        }
        .onChange(of: micKeepAlive) { _, _ in
            AudioKeepAliveManager.syncMicState()
        }
        .onChange(of: focusWakeupEnabled) { _, _ in
            NotificationCenter.default.post(name: .focusWakeupSettingDidChange, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modesDidChange)) { _ in
            reloadLauncherModes()
        }
        .sheet(item: $launcherHotkeyRecordingTarget) { target in
            HotkeyRecordingSheet(
                target: target,
                checkConflict: { code, mods in
                    launcherHotkeyConflict(for: target.id, code: code, modifiers: mods)
                },
                onConfirm: { code, mods, style in
                    updateLauncherHotkey(code: code, modifiers: mods, style: style)
                    launcherHotkeyRecordingTarget = nil
                },
                onCancel: { launcherHotkeyRecordingTarget = nil }
            )
        }
    }

    // MARK: - Layout Helpers

    private func moduleHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(TF.settingsText)
                .padding(.bottom, 12)
        }
    }

    private func moduleSpacer() -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)
            Divider()
            Spacer().frame(height: 20)
        }
    }

    private func twoColumnLayout<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                left()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                right()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 16) {
                left()
                right()
            }
        }
    }

    // MARK: - Row Builders

    private func settingsToggleRow(_ label: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    private var startSoundRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("提示音", "Start Sound").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $startSound,
                options: StartSoundStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            .onChange(of: startSound) { _, newValue in
                if let style = StartSoundStyle(rawValue: newValue) {
                    SoundFeedback.previewStartSound(style)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var visualStyleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("录音动效", "Visual Style").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsSegmentedPicker(
                selection: $visualStyle,
                options: [
                    ("classic", L("线条", "Lines")),
                    ("dual", L("粒子云", "Blocks")),
                    ("timeline", L("电平", "Minimal")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("开机自动启动", "Launch at Startup").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { launchAtLogin ? "on" : "off" },
                    set: { launchAtLogin = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var volumeReductionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("录音时降低音量", "Lower System Volume").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { String(volumeReduction) },
                    set: { volumeReduction = Int($0) ?? -1 }
                ),
                options: [
                    ("-1", L("不降低", "Off")),
                    ("50", "50%"),
                    ("40", "40%"),
                    ("30", "30%"),
                    ("20", "20%"),
                    ("10", "10%"),
                    ("0", L("静音", "Mute")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var stripPunctuationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("去句末标点", "Strip Trailing Punctuation").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $stripTrailingPunctuation,
                options: [
                    ("off", L("不去掉", "Off")),
                    ("period", L("去掉句号", "Periods Only")),
                    ("all", L("去掉所有标点", "All Punctuation")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var hoverPreviewRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("悬停文字预览", "Hover Text Preview").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("鼠标悬停悬浮条时显示完整文本", "Show full text when hovering the bar"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { hoverTranscriptPreview ? "on" : "off" },
                    set: { hoverTranscriptPreview = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var microphoneSelectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("麦克风", "Microphone").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("选择音频输入设备", "Select audio input device"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Button {
                    refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新麦克风列表", "Refresh microphone list"))
            }
            settingsDropdown(
                selection: $selectedMicrophoneUID,
                options: [("", L("系统默认", "System Default"))] + availableMicrophones.map { ($0.uid, $0.name) }
            )
        }
        .padding(.vertical, 6)
    }

    private func refreshMicrophones() {
        availableMicrophones = AudioCaptureEngine.availableAudioDevices()
        if !selectedMicrophoneUID.isEmpty,
           !availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            selectedMicrophoneUID = ""
        }
    }

    private var speakerSelectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("提示音输出", "Alert Output").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("选择提示音播放设备", "Select alert sound device"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Button {
                    refreshSpeakers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新输出设备列表", "Refresh output device list"))
            }
            settingsDropdown(
                selection: $selectedSpeakerUID,
                options: [("", L("系统默认", "System Default"))] + availableSpeakers.map { ($0.uid, $0.name) }
            )
        }
        .padding(.vertical, 6)
    }

    private func refreshSpeakers() {
        availableSpeakers = SoundFeedback.availableOutputDevices()
        if !selectedSpeakerUID.isEmpty,
           !availableSpeakers.contains(where: { $0.uid == selectedSpeakerUID }) {
            selectedSpeakerUID = ""
        }
    }

    private var micKeepAliveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("麦克风保活", "Mic Keep-Alive").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("防止蓝牙麦克风断开", "Prevent BT mic disconnect"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { micKeepAlive ? "on" : "off" },
                    set: { micKeepAlive = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var focusWakeupRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("自动聚焦听写", "Focus Auto Dictation").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("文本框聚焦后等待声音", "Listen after text focus"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { focusWakeupEnabled ? "on" : "off" },
                    set: { focusWakeupEnabled = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var noiseCalibrationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("环境底噪", "Noise Floor").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("用于自动启动和判停", "For wake and stop thresholds"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            HStack(spacing: 8) {
                Button {
                    recalibrateNoiseFloor()
                } label: {
                    Text(isCalibratingNoise ? L("校准中...", "Calibrating...") : L("重新校准底噪", "Recalibrate"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isCalibratingNoise ? TF.settingsTextTertiary : TF.settingsText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(TF.settingsCardAlt)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isCalibratingNoise)
            }
            if !noiseCalibrationStatus.isEmpty {
                Text(noiseCalibrationStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private var autoStopSilenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("自动提交延迟", "Auto Submit Delay").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("说话停止后多久打字", "Silence before typing"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { Self.autoStopSilenceOption(for: focusAutoStopSilenceSeconds) },
                    set: { focusAutoStopSilenceSeconds = Double($0) ?? 0.9 }
                ),
                options: [
                    ("0.6", L("0.6 秒", "0.6 sec")),
                    ("0.9", L("0.9 秒", "0.9 sec")),
                    ("1.2", L("1.2 秒", "1.2 sec")),
                    ("1.5", L("1.5 秒", "1.5 sec")),
                    ("2.0", L("2.0 秒", "2.0 sec")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var launcherHotkeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("启动器热键", "Launcher Hotkey").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("呼出 Agent 路由", "Open agent router"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            HStack(spacing: 8) {
                Text(launcherHotkeyDisplay)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                Button {
                    launcherHotkeyRecordingTarget = RecordingTarget(
                        id: ProcessingMode.agentRouterModeId,
                        name: L("启动器", "Launcher"),
                        currentStyle: agentRouterMode.hotkeyStyle
                    )
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                }
                .buttonStyle(.plain)
                .help(L("录制启动器热键", "Record launcher hotkey"))
            }
        }
        .padding(.vertical, 6)
    }

    private var launcherTerminalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("终端", "Terminal").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("启动 Agent 使用的终端", "Terminal used for agents"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Button {
                    refreshLauncherTerminals()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新终端列表", "Refresh terminal list"))
            }
            settingsDropdown(
                selection: $agentLauncherTerminal,
                options: launcherTerminalOptions,
                icon: "terminal"
            )
        }
        .padding(.vertical, 6)
    }

    private var agentRouterMode: ProcessingMode {
        launcherModes.first { $0.id == ProcessingMode.agentRouterModeId } ?? ProcessingMode.agentRouterMode
    }

    private var launcherHotkeyDisplay: String {
        guard let keyCode = agentRouterMode.hotkeyCode else {
            return L("未设置", "Not set")
        }
        return HotkeyRecorderView.keyDisplayName(keyCode: keyCode, modifiers: agentRouterMode.hotkeyModifiers)
    }

    private var launcherTerminalOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [("auto", L("自动检测", "Auto Detect"))]
        options.append(contentsOf: availableLauncherTerminals.map { ($0.rawValue, $0.displayName) })

        if agentLauncherTerminal != "auto",
           let selected = AgentLauncherTerminal(rawValue: agentLauncherTerminal),
           !availableLauncherTerminals.contains(selected) {
            options.insert(
                (selected.rawValue, L("\(selected.displayName)（未安装）", "\(selected.displayName) (Not Installed)")),
                at: 1
            )
        }
        return options
    }

    private var preserveClipboardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("注入剪贴板", "Copy to Clipboard").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("开启后始终写入剪贴板", "Always copy to clipboard"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { preserveClipboard ? "off" : "on" },
                    set: { preserveClipboard = $0 != "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var dockIconRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("DOCK 图标", "Dock Icon").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("隐藏后仅保留菜单栏", "Menu bar only when hidden"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: Binding(
                    get: { showDockIcon ? "on" : "off" },
                    set: { showDockIcon = $0 == "on" }
                ),
                options: [
                    ("on", L("显示", "Show")),
                    ("off", L("隐藏", "Hide")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("界面语言", "Primary Language").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $language,
                options: AppLanguage.allCases.map { ($0.rawValue, $0.displayName) },
                icon: "globe"
            )
        }
        .padding(.vertical, 6)
    }

    /// Reloads persisted processing modes used by the launcher hotkey row.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Updates local settings state from `ModeStorage`.
    private func reloadLauncherModes() {
        launcherModes = ModeStorage().load()
    }

    /// Refreshes the installed terminal list for the launcher dropdown.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Updates the terminal choices displayed in Settings.
    private func refreshLauncherTerminals() {
        availableLauncherTerminals = AgentLauncherTerminal.available()
    }

    /// Finds an existing hotkey owner outside the launcher mode.
    ///
    /// Args:
    ///   targetId: Mode being edited.
    ///   code: Captured key code.
    ///   modifiers: Captured modifier mask.
    ///
    /// Returns:
    ///   The conflicting mode, or `nil` when the hotkey is available.
    private func launcherHotkeyConflict(for targetId: UUID, code: Int?, modifiers: UInt64?) -> ProcessingMode? {
        guard let code else { return nil }
        let normalizedModifiers = modifiers ?? 0
        return launcherModes.first { mode in
            mode.id != targetId &&
            mode.hotkeyCode == code &&
            (mode.hotkeyModifiers ?? 0) == normalizedModifiers
        }
    }

    /// Updates the Agent Router mode hotkey from the General settings page.
    ///
    /// Args:
    ///   code: Captured key code.
    ///   modifiers: Captured modifier mask.
    ///   style: Whether the hotkey is hold-to-record or toggle.
    ///
    /// Returns:
    ///   Nothing. Persists mode settings and broadcasts the hotkey change.
    private func updateLauncherHotkey(code: Int, modifiers: UInt64?, style: ProcessingMode.HotkeyStyle) {
        let normalizedModifiers = modifiers ?? 0
        if let conflictIdx = launcherModes.firstIndex(where: {
            $0.id != ProcessingMode.agentRouterModeId &&
            $0.hotkeyCode == code &&
            ($0.hotkeyModifiers ?? 0) == normalizedModifiers
        }) {
            launcherModes[conflictIdx].hotkeyCode = nil
            launcherModes[conflictIdx].hotkeyModifiers = nil
        }

        let launcherIdx = ensureAgentRouterModeIndex()
        launcherModes[launcherIdx].hotkeyCode = code
        launcherModes[launcherIdx].hotkeyModifiers = modifiers
        launcherModes[launcherIdx].hotkeyStyle = style
        persistLauncherModes()
    }

    /// Ensures the Agent Router mode exists before editing launcher settings.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Index of the Agent Router mode in the local mode array.
    private func ensureAgentRouterModeIndex() -> Int {
        if let idx = launcherModes.firstIndex(where: { $0.id == ProcessingMode.agentRouterModeId }) {
            return idx
        }
        launcherModes.append(ProcessingMode.agentRouterMode)
        return launcherModes.count - 1
    }

    /// Persists launcher mode edits and asks the app to re-register hotkeys.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Logs write failures instead of silently swallowing them.
    private func persistLauncherModes() {
        do {
            try ModeStorage().save(launcherModes)
            appState.availableModes = launcherModes
            if appState.currentMode.id == ProcessingMode.agentRouterModeId,
               let updated = launcherModes.first(where: { $0.id == ProcessingMode.agentRouterModeId }) {
                appState.currentMode = updated
            }
            NotificationCenter.default.post(name: .modesDidChange, object: nil)
        } catch {
            DebugFileLogger.log("GeneralSettingsTab failed to save launcher hotkey: \(error.localizedDescription)")
        }
    }

    /// Runs a manual bottom-noise calibration from Settings.
    ///
    /// The behavior mirrors the Python MyType Web UI: reject active recordings,
    /// ask the user to stay quiet, pause focus listening, then show either the
    /// measured noise floor and stop threshold or the calibration error.
    private func recalibrateNoiseFloor() {
        guard !isCalibratingNoise else { return }
        if appState.barPhase == .recording || appState.barPhase == .preparing {
            noiseCalibrationStatus = L("正在录音，不能重新校准底噪", "Recording is active; cannot recalibrate")
            return
        }

        let duration: TimeInterval = 1.5
        isCalibratingNoise = true
        noiseCalibrationStatus = L(
            "请保持安静 \(String(format: "%.1f", duration)) 秒",
            "Keep quiet for \(String(format: "%.1f", duration)) seconds"
        )
        NotificationCenter.default.post(name: .noiseFloorCalibrationWillStart, object: nil)

        Task {
            let result = await NoiseFloorCalibrator.calibrate(
                duration: duration,
                minSamples: 10,
                source: "settings"
            )
            await MainActor.run {
                isCalibratingNoise = false
                if result.success {
                    let floor = Int((result.noiseFloor ?? 0).rounded())
                    let threshold = Int(result.threshold.rounded())
                    noiseCalibrationStatus = L(
                        "底噪 \(floor)，判停阈值 \(threshold)",
                        "Noise \(floor), stop threshold \(threshold)"
                    )
                } else {
                    noiseCalibrationStatus = result.error ?? L("底噪校准失败", "Noise calibration failed")
                }
                NotificationCenter.default.post(name: .noiseFloorCalibrationDidFinish, object: nil)
            }
        }
    }

    /// Resolves the nearest supported silence-delay option.
    ///
    /// Args:
    ///   value: Saved silence delay in seconds.
    ///
    /// Returns:
    ///   A dropdown option string nearest to the saved value.
    private static func autoStopSilenceOption(for value: Double) -> String {
        let options = [0.6, 0.9, 1.2, 1.5, 2.0]
        let nearest = options.min(by: { abs($0 - value) < abs($1 - value) }) ?? 0.9
        return String(format: "%.1f", nearest)
    }

    // MARK: - Permission Block

    private func permissionBlock(
        icon: String,
        name: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(granted ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                )

            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)

            Spacer()

            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已授权", "Authorized"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
            } else {
                Button { action() } label: {
                    Text(L("授权", "Grant"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsAccentAmber))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
    }

    // MARK: - Permissions

    private func checkPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    // MARK: - Login Item

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }

    private func syncLoginItemState() {
        let status = SMAppService.mainApp.status
        if status == .notRegistered, !UserDefaults.standard.bool(forKey: "tf_didInitialLoginItemSetup") {
            // First launch: register login item by default
            UserDefaults.standard.set(true, forKey: "tf_didInitialLoginItemSetup")
            setLoginItem(enabled: true)
        } else {
            launchAtLogin = status == .enabled
        }
    }
}
