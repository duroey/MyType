import SwiftUI
import ServiceManagement
import AVFoundation
import AppKit
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
    @AppStorage(RecordingVisualStyle.storageKey) private var visualStyle = RecordingVisualStyle.defaultValue
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage("tf_preserveClipboard") private var preserveClipboard = true
    @AppStorage("tf_showDockIcon") private var showDockIcon = true
    @AppStorage("tf_bypassProxy") private var bypassProxy = "off"
    @AppStorage("tf_stripTrailingPunctuation") private var stripTrailingPunctuation = "off"
    @AppStorage("tf_preserveCJKLatinSpacing") private var preserveCJKLatinSpacing = true
    @AppStorage("tf_hoverTranscriptPreview") private var hoverTranscriptPreview = true
    @AppStorage("tf_micKeepAlive") private var micKeepAlive = false
    @AppStorage("tf_focusWakeupEnabled") private var focusWakeupEnabled = true
    @AppStorage(FocusAutoStopSilenceSetting.storageKey) private var focusAutoStopSilenceSeconds = FocusAutoStopSilenceSetting.defaultSeconds
    @AppStorage(FocusWakeupController.focusWakeupModeIdKey) private var focusWakeupModeId = ""
    @AppStorage("tf_agentLauncherTerminal") private var agentLauncherTerminal = "auto"
    @AppStorage(AudioInputDevicePreferenceStore.modeKey) private var microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
    @AppStorage(AudioInputDevicePreferenceStore.priorityEntriesKey) private var microphonePriorityEntriesStorage = ""
    @AppStorage("tf_selectedSpeakerUID") private var selectedSpeakerUID = ""

    @State private var hasMic = false
    @State private var hasAccessibility = false
    @State private var availableMicrophones: [AudioInputDevice] = []
    @State private var availableSpeakers: [(uid: String, name: String)] = []
    @State private var isCalibratingNoise = false
    @State private var noiseCalibrationStatus = ""
    @State private var focusAutoStopSilenceText = FocusAutoStopSilenceSetting.formatted(FocusAutoStopSilenceSetting.defaultSeconds)
    @State private var launcherModes: [ProcessingMode] = ModeStorage().load()
    @State private var launcherHotkeyRecordingTarget: RecordingTarget?
    @State private var availableLauncherTerminals: [AgentLauncherTerminal] = []
    @State private var showMicrophonePrioritySheet = false
    @State private var draftMicrophonePriorityEntries: [AudioInputDevicePreferenceEntry] = []

    typealias TestStatus = SettingsTestStatus

    enum AudioFeatureSetting {
        case micKeepAlive
        case focusWakeup
    }

    /// Resolves mutually exclusive microphone-owning feature preferences.
    ///
    /// Args:
    ///   micKeepAlive: Current microphone keep-alive preference.
    ///   focusWakeupEnabled: Current focus wakeup preference.
    ///   changedFeature: Feature whose setting was just changed.
    ///   enabled: New enabled state for the changed feature.
    ///
    /// Returns:
    ///   Updated preferences with at most one microphone-owning feature enabled.
    nonisolated static func resolvedAudioFeatureSettings(
        micKeepAlive: Bool,
        focusWakeupEnabled: Bool,
        changedFeature: AudioFeatureSetting,
        enabled: Bool
    ) -> (micKeepAlive: Bool, focusWakeupEnabled: Bool) {
        switch changedFeature {
        case .micKeepAlive:
            return (enabled, enabled ? false : focusWakeupEnabled)
        case .focusWakeup:
            return (enabled ? false : micKeepAlive, enabled)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: L("通用", "GENERAL"),
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

                // Row 4: 自动聚焦模式 / 自动提交延迟
                HStack(alignment: .top, spacing: 16) {
                    focusWakeupModeRow
                        .frame(maxWidth: .infinity)
                    autoStopSilenceRow
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

                // Row 2: 去句末标点 / 中英文空格 / 悬停文字预览
                HStack(alignment: .top, spacing: 16) {
                    stripPunctuationRow
                        .frame(maxWidth: .infinity)
                    cjkLatinSpacingRow
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
        .onReceive(NotificationCenter.default.publisher(for: .audioInputDevicesDidChange)) { _ in
            refreshMicrophones()
        }
        .sheet(item: $launcherHotkeyRecordingTarget) { target in
            HotkeyRecordingSheet(
                target: target,
                checkConflict: { code, mods in
                    launcherHotkeyConflict(for: target.id, code: code, modifiers: mods)
                },
                checkPrefixConflict: { code, mods in
                    launcherHotkeyPrefixConflict(for: target.id, code: code, modifiers: mods)
                },
                onConfirm: { code, mods, style in
                    updateLauncherHotkey(code: code, modifiers: mods, style: style)
                    launcherHotkeyRecordingTarget = nil
                },
                onCancel: { launcherHotkeyRecordingTarget = nil }
            )
        }
        .sheet(isPresented: $showMicrophonePrioritySheet) {
            MicrophonePrioritySheet(
                devices: availableMicrophones,
                initialEntries: draftMicrophonePriorityEntries,
                onCancel: {
                    showMicrophonePrioritySheet = false
                },
                onSave: { entries in
                    saveMicrophonePriority(entries)
                    showMicrophonePrioritySheet = false
                }
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
            settingsDropdown(
                selection: $visualStyle,
                options: RecordingVisualStyle.allCases.map { ($0.rawValue, $0.displayName) }
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

    private var cjkLatinSpacingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("中英文空格", "CJK-Latin Spacing").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { preserveCJKLatinSpacing ? "on" : "off" },
                    set: { preserveCJKLatinSpacing = $0 == "on" }
                ),
                options: [
                    ("on", L("保留", "Keep")),
                    ("off", L("去掉", "Strip")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var hoverPreviewRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("悬停文字预览", "Hover Text Preview").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
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
            microphonePreferenceDropdown
        }
        .padding(.vertical, 6)
    }

    private func refreshMicrophones() {
        let devices = AudioCaptureEngine.availableAudioInputDevices()
        availableMicrophones = devices
        AudioInputDeviceMonitor.shared.replaceCachedDevices(devices)
    }

    private var microphonePreferenceDropdown: some View {
        Menu {
            Button {
                setMicrophoneSystemDefault()
            } label: {
                Label(
                    L("跟随系统", "Follow System"),
                    systemImage: microphonePreference == .systemDefault ? "checkmark" : "gearshape"
                )
            }

            if microphonePriorityEntries.isEmpty {
                Button {
                    openMicrophonePrioritySheet()
                } label: {
                    Label(L("指定优先级", "Set Priority"), systemImage: "list.number")
                }
            } else {
                Divider()
                Button {
                    activateMicrophonePriority()
                } label: {
                    Label(
                        microphonePriorityMenuLabel,
                        systemImage: microphonePreference == .priority ? "checkmark" : "list.number"
                    )
                }
                Button {
                    openMicrophonePrioritySheet()
                } label: {
                    Label(L("修改优先级", "Edit Priority"), systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: microphonePreference == .priority ? "list.number" : "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(microphonePreferenceLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsCardAlt)
            )
        }
        .buttonStyle(.plain)
    }

    private var microphonePreference: AudioInputDevicePreferenceMode {
        AudioInputDevicePreferenceMode(rawValue: microphonePreferenceMode) ?? .systemDefault
    }

    private var microphonePriorityEntries: [AudioInputDevicePreferenceEntry] {
        AudioInputDevicePreferenceStore.priorityEntries(from: microphonePriorityEntriesStorage)
    }

    private var microphonePreferenceLabel: String {
        guard microphonePreference == .priority, !microphonePriorityEntries.isEmpty else {
            return L("跟随系统", "Follow System")
        }
        return L("当前优先级：\(microphonePrioritySummary)",
                 "Priority: \(microphonePrioritySummary)")
    }

    private var microphonePriorityMenuLabel: String {
        L("使用当前优先级", "Use Current Priority")
    }

    private var microphonePrioritySummary: String {
        let names = microphonePriorityEntries.map { displayName(for: $0) }
        let visibleNames = Array(names.prefix(2))
        let hiddenCount = max(0, names.count - visibleNames.count)
        let hiddenSummary = hiddenCount > 0 ? [L("另 \(hiddenCount) 个", "\(hiddenCount) more")] : []
        return (visibleNames + hiddenSummary + [L("跟随系统", "System")]).joined(separator: L("、", ", "))
    }

    private func openMicrophonePrioritySheet() {
        refreshMicrophones()
        let currentEntries = refreshedPriorityEntries(microphonePriorityEntries)
        draftMicrophonePriorityEntries = currentEntries.isEmpty
            ? availableMicrophones.map { AudioInputDevicePreferenceEntry(uid: $0.uid, name: $0.name) }
            : currentEntries
        showMicrophonePrioritySheet = true
    }

    private func refreshedPriorityEntries(
        _ entries: [AudioInputDevicePreferenceEntry]
    ) -> [AudioInputDevicePreferenceEntry] {
        entries.map { entry in
            guard let device = availableMicrophones.first(where: { $0.uid == entry.uid }) else {
                return entry
            }
            return AudioInputDevicePreferenceEntry(uid: entry.uid, name: device.name)
        }
    }

    private func displayName(for entry: AudioInputDevicePreferenceEntry) -> String {
        availableMicrophones.first(where: { $0.uid == entry.uid })?.name ?? entry.name
    }

    private func saveMicrophonePriority(_ entries: [AudioInputDevicePreferenceEntry]) {
        let storage = AudioInputDevicePreferenceStore.storageValue(for: entries)
        guard !storage.isEmpty else {
            setMicrophoneSystemDefault()
            return
        }
        AudioInputDevicePreferenceStore.savePriorityEntries(entries)
        microphonePreferenceMode = AudioInputDevicePreferenceMode.priority.rawValue
        microphonePriorityEntriesStorage = storage
        syncRememberedMicrophoneProfile(with: entries)
    }

    private func setMicrophoneSystemDefault() {
        AudioInputDevicePreferenceStore.resetToSystemDefault(clearPriority: true)
        microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
        microphonePriorityEntriesStorage = ""
        RememberedMicrophoneProfileStore.clear()
        NotificationCenter.default.post(name: .rememberedMicrophoneProfileDidChange, object: nil)
    }

    /// Re-enables the saved microphone priority list and restarts dependent capture.
    ///
    /// Returns:
    ///   Nothing. Updates persisted preference state and broadcasts the change.
    private func activateMicrophonePriority() {
        let entries = microphonePriorityEntries
        guard !entries.isEmpty else { return }
        AudioInputDevicePreferenceStore.savePriorityEntries(entries)
        microphonePreferenceMode = AudioInputDevicePreferenceMode.priority.rawValue
        syncRememberedMicrophoneProfile(with: entries)
    }

    /// Synchronizes MyType's Auto Focus profile with the priority-list selection.
    ///
    /// Args:
    ///   entries: Ordered microphone preferences saved by the user.
    ///
    /// Returns:
    ///   Nothing. Stores the currently resolvable preference and broadcasts the change.
    private func syncRememberedMicrophoneProfile(
        with entries: [AudioInputDevicePreferenceEntry]
    ) {
        let preferredUID = AudioInputDevicePreferenceStore.resolvedDevice(
            devices: availableMicrophones,
            priorityEntries: entries
        )?.uid ?? entries.first?.uid
        guard let preferredUID else {
            RememberedMicrophoneProfileStore.clear()
            NotificationCenter.default.post(name: .rememberedMicrophoneProfileDidChange, object: nil)
            return
        }
        RememberedMicrophoneProfileStore.replace(
            deviceUID: preferredUID,
            focusWakeupEnabled: focusWakeupEnabled
        )
        NotificationCenter.default.post(name: .rememberedMicrophoneProfileDidChange, object: nil)
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
                    set: { applyAudioFeatureSetting(.micKeepAlive, enabled: $0 == "on") }
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
                    set: { applyAudioFeatureSetting(.focusWakeup, enabled: $0 == "on") }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    /// Applies a mutually exclusive microphone feature setting from the UI.
    ///
    /// Args:
    ///   changedFeature: Feature changed by the user.
    ///   enabled: New enabled state for the changed feature.
    private func applyAudioFeatureSetting(_ changedFeature: AudioFeatureSetting, enabled: Bool) {
        let resolved = Self.resolvedAudioFeatureSettings(
            micKeepAlive: micKeepAlive,
            focusWakeupEnabled: focusWakeupEnabled,
            changedFeature: changedFeature,
            enabled: enabled
        )
        let focusChanged = focusWakeupEnabled != resolved.focusWakeupEnabled
        micKeepAlive = resolved.micKeepAlive
        focusWakeupEnabled = resolved.focusWakeupEnabled
        RememberedMicrophoneProfileStore.updateFocusWakeupEnabled(resolved.focusWakeupEnabled)
        AudioKeepAliveManager.syncMicState()
        if focusChanged {
            NotificationCenter.default.post(name: .focusWakeupSettingDidChange, object: nil)
        }
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
            HStack(spacing: 8) {
                FixedWidthTextField(
                    text: Binding(
                        get: { focusAutoStopSilenceText },
                        set: { updateAutoStopSilenceText($0) }
                    ),
                    placeholder: FocusAutoStopSilenceSetting.formatted(FocusAutoStopSilenceSetting.defaultSeconds),
                    commitOnReturnOrOutsideClick: true,
                    onEditingEnded: { commitAutoStopSilenceText($0) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 36)

                Text(L("秒", "sec"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsCardAlt)
            )
        }
        .padding(.vertical, 6)
        .onAppear {
            syncAutoStopSilenceTextFromStoredValue()
        }
    }

    private var focusWakeupModeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("自动聚焦模式", "Focus Mode").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(L("直接说话时使用", "Used when speaking directly"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            settingsDropdown(
                selection: focusWakeupModeSelection,
                options: focusWakeupModeOptions,
                icon: "wand.and.stars"
            )
        }
        .padding(.vertical, 6)
    }

    private var focusWakeupModeSelection: Binding<String> {
        Binding(
            get: { resolvedFocusWakeupModeId },
            set: { focusWakeupModeId = $0 }
        )
    }

    private var focusWakeupModeOptions: [(value: String, label: String)] {
        let textModes = launcherModes.filter(FocusWakeupController.isTextProducingFocusMode)
        let supportedModes = ASRProviderRegistry.supportedModes(
            from: textModes,
            for: KeychainService.selectedASRProvider
        )
        let selectableModes = supportedModes.isEmpty ? textModes : supportedModes
        return selectableModes.map { ($0.id.uuidString, $0.name) }
    }

    private var resolvedFocusWakeupModeId: String {
        let storedId = focusWakeupModeId.isEmpty ? nil : focusWakeupModeId
        return FocusWakeupController.resolvedFocusWakeupMode(
            modes: launcherModes,
            storedModeId: storedId,
            provider: KeychainService.selectedASRProvider
        )
        .id
        .uuidString
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

    /// Reloads persisted processing modes used by General settings rows.
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
        return launcherModes.first { mode in
            guard mode.id != targetId, let otherCode = mode.hotkeyCode else {
                return false
            }
            return ModeBinding.hotkeysAreEquivalent(
                keyCode: code,
                modifiers: modifiers,
                otherKeyCode: otherCode,
                otherModifiers: mode.hotkeyModifiers
            )
        }
    }

    /// Finds a launcher hotkey that has a modifier-prefix conflict.
    ///
    /// Args:
    ///   targetId: Mode being edited.
    ///   code: Captured key code.
    ///   modifiers: Captured modifier mask.
    ///
    /// Returns:
    ///   The conflicting mode, or `nil` when no prefix conflict exists.
    private func launcherHotkeyPrefixConflict(
        for targetId: UUID,
        code: Int?,
        modifiers: UInt64?
    ) -> ProcessingMode? {
        guard let code else { return nil }
        return launcherModes.first { mode in
            guard mode.id != targetId, let otherCode = mode.hotkeyCode else {
                return false
            }
            return ModeBinding.hasModifierPrefixConflict(
                keyCode: code,
                modifiers: modifiers,
                otherKeyCode: otherCode,
                otherModifiers: mode.hotkeyModifiers
            )
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

    /// Syncs the editable silence delay field from persisted settings.
    ///
    /// Migrates legacy fast values to the current default while keeping the UI
    /// text in one-decimal-place form.
    private func syncAutoStopSilenceTextFromStoredValue() {
        let normalized = FocusAutoStopSilenceSetting.normalized(focusAutoStopSilenceSeconds)
        focusAutoStopSilenceSeconds = normalized
        focusAutoStopSilenceText = FocusAutoStopSilenceSetting.formatted(normalized)
    }

    /// Updates the persisted silence delay from editable settings text.
    ///
    /// Args:
    ///   text: User-entered seconds text.
    private func updateAutoStopSilenceText(_ text: String) {
        focusAutoStopSilenceText = text
        focusAutoStopSilenceSeconds = FocusAutoStopSilenceSetting.parsed(text)
    }

    /// Commits the editable silence delay when text editing ends.
    ///
    /// Args:
    ///   text: Final user-entered seconds text.
    private func commitAutoStopSilenceText(_ text: String) {
        let normalized = FocusAutoStopSilenceSetting.parsed(text)
        focusAutoStopSilenceSeconds = normalized
        focusAutoStopSilenceText = FocusAutoStopSilenceSetting.formatted(normalized)
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

private struct MicrophonePrioritySheet: View {
    let devices: [AudioInputDevice]
    let initialEntries: [AudioInputDevicePreferenceEntry]
    let onCancel: () -> Void
    let onSave: ([AudioInputDevicePreferenceEntry]) -> Void

    @State private var orderedEntries: [AudioInputDevicePreferenceEntry]

    init(
        devices: [AudioInputDevice],
        initialEntries: [AudioInputDevicePreferenceEntry],
        onCancel: @escaping () -> Void,
        onSave: @escaping ([AudioInputDevicePreferenceEntry]) -> Void
    ) {
        self.devices = devices
        self.initialEntries = initialEntries
        self.onCancel = onCancel
        self.onSave = onSave
        _orderedEntries = State(initialValue: initialEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(L("麦克风优先级", "Microphone Priority"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                    Spacer()
                    Label(L("末尾跟随系统", "System fallback"), systemImage: "gearshape")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(TF.settingsCardAlt.opacity(0.75)))
                }

                Text(L("点一行加入或移除，箭头调整顺序。",
                       "Click a row to add or remove it; use arrows to reorder."))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if allEntries.isEmpty {
                        Text(L("当前没有可用输入设备。", "No input devices are currently available."))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ForEach(allEntries) { entry in
                            deviceRow(entry)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: listHeight)
            .background(RoundedRectangle(cornerRadius: 10).fill(TF.settingsCardAlt.opacity(0.35)))

            HStack(spacing: 10) {
                Text(selectionFooterText)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                Spacer()
                Button(L("取消", "Cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                Button {
                    onSave(orderedEntries)
                } label: {
                    Text(L("保存", "Save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(orderedEntries.isEmpty ? TF.settingsTextTertiary : TF.settingsAccentAmber)
                        )
                }
                .buttonStyle(.plain)
                .disabled(orderedEntries.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(TF.settingsBg)
    }

    private var allEntries: [AudioInputDevicePreferenceEntry] {
        var result = orderedEntries
        for device in devices where !result.contains(where: { $0.uid == device.uid }) {
            result.append(AudioInputDevicePreferenceEntry(uid: device.uid, name: device.name))
        }
        return result
    }

    private var listHeight: CGFloat {
        guard !allEntries.isEmpty else {
            return 52
        }
        let visibleRows = min(allEntries.count, 5)
        let rowHeight: CGFloat = 40
        let rowSpacing: CGFloat = 5
        let verticalPadding: CGFloat = 12
        return CGFloat(visibleRows) * rowHeight
            + CGFloat(max(visibleRows - 1, 0)) * rowSpacing
            + verticalPadding
    }

    private var selectionFooterText: String {
        L("已选 \(orderedEntries.count) 个，最后自动跟随系统",
          "\(orderedEntries.count) selected, then system fallback")
    }

    private func deviceRow(_ entry: AudioInputDevicePreferenceEntry) -> some View {
        let selectedIndex = orderedEntries.firstIndex(where: { $0.uid == entry.uid })
        let device = devices.first { $0.uid == entry.uid }
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let selectedIndex {
                    Text("\(selectedIndex + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(TF.settingsNavActive))
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 22, height: 22)
                }

                Text(device?.name ?? entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(device.map { $0.category.displayName } ?? L("未连接", "Offline"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(TF.settingsBg.opacity(0.72)))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleEntry(entry)
            }

            if let selectedIndex {
                HStack(spacing: 2) {
                    iconButton("chevron.up", disabled: selectedIndex == 0) {
                        moveEntry(from: selectedIndex, by: -1)
                    }
                    iconButton("chevron.down", disabled: selectedIndex == orderedEntries.count - 1) {
                        moveEntry(from: selectedIndex, by: 1)
                    }
                    iconButton("minus.circle", disabled: false) {
                        orderedEntries.remove(at: selectedIndex)
                    }
                }
            } else {
                iconButton("plus.circle", disabled: false) {
                    toggleEntry(entry)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedIndex == nil ? TF.settingsCardAlt.opacity(0.72) : TF.settingsCardAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedIndex == nil ? Color.clear : TF.settingsNavActive.opacity(0.22), lineWidth: 1)
        )
    }

    private func iconButton(_ systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(disabled ? TF.settingsTextTertiary.opacity(0.4) : TF.settingsTextTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func moveEntry(from index: Int, by offset: Int) {
        let newIndex = index + offset
        guard orderedEntries.indices.contains(index), orderedEntries.indices.contains(newIndex) else {
            return
        }
        let entry = orderedEntries.remove(at: index)
        orderedEntries.insert(entry, at: newIndex)
    }

    private func toggleEntry(_ entry: AudioInputDevicePreferenceEntry) {
        if let index = orderedEntries.firstIndex(where: { $0.uid == entry.uid }) {
            orderedEntries.remove(at: index)
        } else {
            orderedEntries.append(entry)
        }
    }
}
