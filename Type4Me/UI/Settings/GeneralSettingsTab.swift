import SwiftUI
import ServiceManagement
import AVFoundation
import AppKit
import ApplicationServices
import Type4MeReviseCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - General Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct GeneralSettingsTab: View, SettingsCardHelpers {

    @Environment(AppState.self) private var appState
    var showsHeader = true

    // MARK: - Global

    @AppStorage("tf_startSound") private var startSound = StartSoundStyle.chime.rawValue
    @AppStorage("tf_launchAtLogin") private var launchAtLogin = true
    @AppStorage("tf_volumeReduction") private var volumeReduction = -1
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage(ClipboardOutputPolicy.storageKey)
    private var clipboardOutputPolicyRaw = ClipboardOutputPolicy.defaultValue.rawValue
    @AppStorage("tf_showDockIcon") private var showDockIcon = true
    @AppStorage("tf_bypassProxy") private var bypassProxy = "off"
    @AppStorage("tf_micKeepAlive") private var micKeepAlive = false
    @AppStorage("tf_focusWakeupEnabled") private var focusWakeupEnabled = true
    @AppStorage(FocusAcousticMode.storageKey) private var focusAcousticMode = FocusAcousticMode.noisy.rawValue
    @AppStorage(FocusAutoStopSilenceSetting.storageKey) private var focusAutoStopSilenceSeconds = FocusAutoStopSilenceSetting.defaultSeconds
    @AppStorage(FocusWakeupController.focusWakeupModeIdKey) private var focusWakeupModeId = ""
    @AppStorage("tf_agentLauncherTerminal") private var agentLauncherTerminal = "auto"
    @AppStorage(CrossModeFinishPreference.storageKey) private var allowCrossModeFinish = CrossModeFinishPreference.defaultValue
    @AppStorage(AudioInputDevicePreferenceStore.modeKey) private var microphonePreferenceMode = AudioInputDevicePreferenceMode.systemDefault.rawValue
    @AppStorage(AudioInputDevicePreferenceStore.priorityEntriesKey) private var microphonePriorityEntriesStorage = ""
    @AppStorage("tf_selectedSpeakerUID") private var selectedSpeakerUID = ""
    @AppStorage(DebugSettingsAvailability.defaultsKey)
    private var debugPanelEnabled = DebugSettingsAvailability.defaultEnabled

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

    @State private var reviseSettings: ReviseSettings = ReviseSettingsStore.shared.load()
    @State private var reviseKeyCode: Int? = ReviseSettingsStore.shared.load().hotkey?.keyCode
    @State private var reviseModifiers: UInt64? = ReviseSettingsStore.shared.load().hotkey?.modifiers

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
            if showsHeader {
                SettingsSectionHeader(
                    label: L("通用", "GENERAL"),
                    title: L("通用设置", "General Settings"),
                    description: L("偏好设置与系统权限。快捷键请在「处理模式」中配置。", "Preferences and permissions. Hotkeys are configured in Modes.")
                )
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 1: 录音设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("录音设置", "Recording"), icon: "mic.fill") {
                microphoneSelectionRow
                SettingsDivider()
                volumeReductionRow
                SettingsDivider()
                startSoundRow
                SettingsDivider()
                speakerSelectionRow
                SettingsDivider()
                micKeepAliveRow
                SettingsDivider()
                crossModeFinishRow
                SettingsDivider()
                focusWakeupRow
                SettingsDivider()
                focusAcousticModeRow
                SettingsDivider()
                noiseCalibrationRow
                SettingsDivider()
                focusWakeupModeRow
                SettingsDivider()
                autoStopSilenceRow
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD: 改口设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("改口设置", "Revise"), icon: "arrow.triangle.2.circlepath") {
                reviseToggleRow
                if reviseSettings.enabled {
                    SettingsDivider()
                    reviseHotkeyRow
                    SettingsDivider()
                    reviseHotkeyStyleRow
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 3: 系统集成
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("系统集成", "System Integration"), icon: "gearshape.2") {
                launchAtLoginRow
                SettingsDivider()
                dockIconRow
                SettingsDivider()
                preserveClipboardRow
                SettingsDivider()
                languageRow
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
                permissionRow(
                    name: L("麦克风", "Microphone"), granted: hasMic
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

                SettingsDivider()

                permissionRow(
                    name: L("辅助功能", "Accessibility"), granted: hasAccessibility
                ) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    hasAccessibility = AXIsProcessTrustedWithOptions(options)
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // CARD 5: 高级设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("高级设置", "Advanced"), icon: "wrench.and.screwdriver") {
                settingsOptionRow(
                    L("绕过系统代理", "Bypass System Proxy"),
                    subtitle: L("不经过代理软件，直连对应服务器", "Connect directly to servers, bypassing proxy")
                ) {
                    settingsDropdown(
                        selection: $bypassProxy,
                        options: [
                            ("off", L("关闭", "Off")),
                            ("all", L("全局绕过", "All Connections")),
                            ("asr", L("语音识别绕过", "ASR Only")),
                            ("llm", L("文本处理 LLM 绕过", "LLM Only")),
                        ]
                    )
                }
                #if TYPE4ME_DEV_BUILD
                SettingsDivider()
                settingsToggleRow(
                    L("Debug 模式", "Debug Mode"),
                    subtitle: L(
                        "在左侧菜单显示调试与诊断入口。",
                        "Show the Debug & Diagnostics entry in the sidebar."
                    ),
                    isOn: $debugPanelEnabled
                )
                #endif
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
            NotificationCenter.default.post(name: .focusWakeupSettingDidChange, object: nil)
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
                    launcherHotkeyConflict(for: target.modeId, code: code, modifiers: mods)
                },
                checkDuplicateInMode: { code, mods in
                    launcherHotkeyDuplicate(
                        for: target.modeId,
                        excluding: target.editingBindingId,
                        code: code,
                        modifiers: mods
                    )
                },
                checkPrefixConflict: { code, mods in
                    launcherHotkeyPrefixConflict(for: target.modeId, code: code, modifiers: mods)
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

    // MARK: - Row Builders

    private var startSoundRow: some View {
        settingsOptionRow(L("提示音", "Start Sound")) {
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
    }

    private var crossModeFinishRow: some View {
        settingsToggleRow(
            L("允许跨模式结束", "Allow Cross-Mode Finish"),
            subtitle: L(
                "开启后，使用结束快捷键所属的模式处理文本",
                "When enabled, process text with the mode whose shortcut ends recording"
            ),
            isOn: $allowCrossModeFinish
        )
    }

    private var launchAtLoginRow: some View {
        let isSupported = LoginItemRegistrationPolicy.supportsCurrentProcess
        return settingsToggleRow(
            L("开机自动启动", "Launch at Startup"),
            subtitle: isSupported ? nil : L(
                "仅在 \(AppIdentity.displayName) 以 App 形式运行时可用",
                "Available only when \(AppIdentity.displayName) runs as an app"
            ),
            isOn: $launchAtLogin,
            isEnabled: isSupported
        )
    }

    private var volumeReductionRow: some View {
        settingsOptionRow(L("录音时降低音量", "Lower System Volume")) {
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
    }

    private var microphoneSelectionRow: some View {
        settingsOptionRow(
            L("麦克风", "Microphone"),
            subtitle: L("选择音频输入设备", "Select audio input device"),
            controlWidth: SettingsControlWidth.provider
        ) {
            HStack(spacing: 8) {
                Button {
                    refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新麦克风列表", "Refresh microphone list"))
                microphonePreferenceDropdown
            }
        }
    }

    private func refreshMicrophones() {
        availableMicrophones = AudioInputDeviceMonitor.shared.refreshSynchronously()
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
            settingsDropdownLabel(
                microphonePreferenceLabel,
                icon: microphonePreference == .priority ? "list.number" : "gearshape"
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
        settingsOptionRow(
            L("提示音输出", "Alert Output"),
            subtitle: L("选择提示音播放设备", "Select alert sound device"),
            controlWidth: SettingsControlWidth.provider
        ) {
            HStack(spacing: 8) {
                Button {
                    refreshSpeakers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
                .help(L("刷新输出设备列表", "Refresh output device list"))
                settingsDropdown(
                    selection: $selectedSpeakerUID,
                    options: [("", L("系统默认", "System Default"))] + availableSpeakers.map { ($0.uid, $0.name) }
                )
            }
        }
    }

    private func refreshSpeakers() {
        availableSpeakers = SoundFeedback.availableOutputDevices()
        if !selectedSpeakerUID.isEmpty,
           !availableSpeakers.contains(where: { $0.uid == selectedSpeakerUID }) {
            selectedSpeakerUID = ""
        }
    }

    private var micKeepAliveRow: some View {
        settingsToggleRow(
            L("麦克风保活", "Mic Keep-Alive"),
            subtitle: L("开启后防止蓝牙麦克风断开", "Prevent Bluetooth microphones from disconnecting"),
            isOn: Binding(
                get: { micKeepAlive },
                set: { applyAudioFeatureSetting(.micKeepAlive, enabled: $0) }
            )
        )
    }

    // MARK: - Revise Settings Rows

    private var reviseToggleRow: some View {
        settingsToggleRow(
            L("启用改口功能", "Enable Revise"),
            subtitle: L(
                "在刚输入的内容后按快捷键口述修改要求，直接原地修改",
                "Revise recent text in-place by speaking instructions with hotkey"
            ),
            isOn: Binding(
                get: { reviseSettings.enabled },
                set: { newValue in
                    reviseSettings.enabled = newValue
                    persistReviseSettings()
                }
            )
        )
    }

    private var reviseHotkeyRow: some View {
        settingsOptionRow(
            L("改口快捷键", "Revise Hotkey"),
            subtitle: L("默认 fn + R", "Default: fn + R"),
            controlWidth: SettingsControlWidth.provider
        ) {
            HotkeyRecorderView(
                keyCode: Binding(
                    get: { reviseKeyCode },
                    set: { newCode in
                        reviseKeyCode = newCode
                        if let code = newCode {
                            var hk = reviseSettings.hotkey ?? ReviseSettings.defaultHotkey
                            hk.keyCode = code
                            hk.modifiers = reviseModifiers
                            reviseSettings.hotkey = hk
                            persistReviseSettings()
                        }
                    }
                ),
                modifiers: Binding(
                    get: { reviseModifiers },
                    set: { newMods in
                        reviseModifiers = newMods
                        if let code = reviseKeyCode {
                            var hk = reviseSettings.hotkey ?? ReviseSettings.defaultHotkey
                            hk.keyCode = code
                            hk.modifiers = newMods
                            reviseSettings.hotkey = hk
                            persistReviseSettings()
                        }
                    }
                )
            )
        }
    }

    private var reviseHotkeyStyleRow: some View {
        settingsOptionRow(
            L("触发方式", "Trigger Style"),
            subtitle: L("长按松开结束，或单击开始/结束", "Hold to speak, or tap to toggle")
        ) {
            settingsSegmentedPicker(
                selection: Binding(
                    get: { (reviseSettings.hotkey?.style ?? .hold).rawValue },
                    set: { rawValue in
                        guard let newStyle = HotkeyStyle(rawValue: rawValue) else { return }
                        var hk = reviseSettings.hotkey ?? ReviseSettings.defaultHotkey
                        hk.style = newStyle
                        reviseSettings.hotkey = hk
                        persistReviseSettings()
                    }
                ),
                options: [
                    (HotkeyStyle.hold.rawValue, L("长按", "Hold")),
                    (HotkeyStyle.toggle.rawValue, L("单击切换", "Toggle")),
                ]
            )
            .frame(width: 164)
        }
    }

    private func persistReviseSettings() {
        _ = try? ReviseSettingsStore.shared.save(reviseSettings)
        NotificationCenter.default.post(name: .reviseSettingsDidChange, object: nil)
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

    /// Selects the next focus recording's acoustic policy without interrupting audio.
    private var focusAcousticModeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("声音触发模式", "Sound Trigger Mode"))
            Picker(L("声音触发模式", "Sound Trigger Mode"), selection: $focusAcousticMode) {
                Text(L("嘈杂模式", "Noisy Mode")).tag(FocusAcousticMode.noisy.rawValue)
                Text(L("安静模式", "Quiet Mode")).tag(FocusAcousticMode.quiet.rawValue)
            }
            .pickerStyle(.segmented)
            Text(L("安静模式：聚焦输入框后先保持安静 3 秒；校准后桌面讲话即可触发。更换麦克风会重新校准。切换从下一次监听生效。",
                   "Quiet Mode: focus a text field and stay quiet for 3 seconds, then speak from your desk. A microphone change recalibrates. Switching applies to the next listening period."))
                .font(.caption)
                .foregroundStyle(TF.settingsTextTertiary)
            Text(L("安静模式使用独立结束规则：低于起录门槛的 60% 持续 0.8 秒后结束，不使用下方的静音时长设置。",
                   "Quiet Mode ends after 0.8 seconds below 60% of its start threshold; the silence-duration setting below does not apply."))
                .font(.caption)
                .foregroundStyle(TF.settingsTextTertiary)
            if appState.quietCalibrationSecondsRemaining > 0 {
                Text(L("请保持安静，校准剩余 \(appState.quietCalibrationSecondsRemaining) 秒",
                       "Stay quiet: \(appState.quietCalibrationSecondsRemaining)s of calibration remaining"))
            }
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
        micKeepAlive = resolved.micKeepAlive
        focusWakeupEnabled = resolved.focusWakeupEnabled
        RememberedMicrophoneProfileStore.updateFocusWakeupEnabled(resolved.focusWakeupEnabled)
        // The app coordinator waits for Focus teardown before enabling keep-alive,
        // including changes that leave Focus disabled throughout.
        NotificationCenter.default.post(name: .focusWakeupSettingDidChange, object: nil)
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
        return selectableModes.map { ($0.id.uuidString, $0.localizedDisplayName) }
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
                        modeId: ProcessingMode.agentRouterModeId,
                        modeName: L("启动器", "Launcher"),
                        editingBindingId: agentRouterBinding?.id,
                        initialKeyCode: agentRouterBinding?.keyCode,
                        initialModifiers: agentRouterBinding?.modifiers,
                        initialStyle: agentRouterBinding?.style ?? .toggle
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

    private var agentRouterBinding: HotkeyBinding? {
        agentRouterMode.hotkeyBindings.first
    }

    private var launcherHotkeyDisplay: String {
        guard let binding = agentRouterBinding else {
            return L("未设置", "Not set")
        }
        return HotkeyRecorderView.keyDisplayName(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers
        )
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
        let policy = ClipboardOutputPolicy(rawValue: clipboardOutputPolicyRaw)
            ?? ClipboardOutputPolicy.defaultValue
        return settingsOptionRow(
            L("剪贴板保留", "Clipboard Retention"),
            subtitle: policy.detail
        ) {
            settingsDropdown(
                selection: $clipboardOutputPolicyRaw,
                options: ClipboardOutputPolicy.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
    }

    private var dockIconRow: some View {
        settingsToggleRow(
            L("显示 Dock 图标", "Show Dock Icon"),
            isOn: $showDockIcon
        )
    }

    private var languageRow: some View {
        settingsOptionRow(L("界面语言", "Primary Language")) {
            settingsDropdown(
                selection: $language,
                options: AppLanguage.allCases.map { ($0.rawValue, $0.displayName) },
                icon: "globe"
            )
        }
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
            mode.id != targetId && mode.hotkeyBindings.contains { binding in
                ModeBinding.hotkeysAreEquivalent(
                    keyCode: code,
                    modifiers: modifiers,
                    otherKeyCode: binding.keyCode,
                    otherModifiers: binding.modifiers
                )
            }
        }
    }

    /// Checks whether another binding in the launcher mode uses the same hotkey.
    ///
    /// Args:
    ///   targetId: Mode being edited.
    ///   editingBindingId: Existing binding currently being replaced, if any.
    ///   code: Captured key code.
    ///   modifiers: Captured modifier mask.
    ///
    /// Returns:
    ///   `true` when another binding in the same mode is equivalent.
    private func launcherHotkeyDuplicate(
        for targetId: UUID,
        excluding editingBindingId: UUID?,
        code: Int?,
        modifiers: UInt64?
    ) -> Bool {
        guard let code,
              let mode = launcherModes.first(where: { $0.id == targetId })
        else { return false }
        return mode.hotkeyBindings.contains { binding in
            binding.id != editingBindingId && ModeBinding.hotkeysAreEquivalent(
                keyCode: code,
                modifiers: modifiers,
                otherKeyCode: binding.keyCode,
                otherModifiers: binding.modifiers
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
            mode.id != targetId && mode.hotkeyBindings.contains { binding in
                ModeBinding.hasModifierPrefixConflict(
                    keyCode: code,
                    modifiers: modifiers,
                    otherKeyCode: binding.keyCode,
                    otherModifiers: binding.modifiers
                )
            }
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
        for index in launcherModes.indices where launcherModes[index].id != ProcessingMode.agentRouterModeId {
            launcherModes[index].hotkeyBindings.removeAll { binding in
                ModeBinding.hotkeysAreEquivalent(
                    keyCode: code,
                    modifiers: modifiers,
                    otherKeyCode: binding.keyCode,
                    otherModifiers: binding.modifiers
                )
            }
        }

        let launcherIdx = ensureAgentRouterModeIndex()
        if let bindingIndex = launcherModes[launcherIdx].hotkeyBindings.indices.first {
            let bindingId = launcherModes[launcherIdx].hotkeyBindings[bindingIndex].id
            launcherModes[launcherIdx].hotkeyBindings[bindingIndex] = HotkeyBinding(
                id: bindingId,
                keyCode: code,
                modifiers: modifiers,
                style: style
            )
        } else {
            launcherModes[launcherIdx].hotkeyBindings = [
                HotkeyBinding(keyCode: code, modifiers: modifiers, style: style),
            ]
        }
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

    // MARK: - Permission Row

    private func permissionRow(
        name: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        settingsOptionRow(
            name,
            subtitle: granted ? L("已获得系统授权", "System permission granted") : L("需要系统授权", "System permission required"),
            controlWidth: 140
        ) {
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
    }

    // MARK: - Permissions

    private func checkPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    // MARK: - Login Item

    private func setLoginItem(enabled: Bool) {
        guard LoginItemRegistrationPolicy.supportsCurrentProcess else {
            launchAtLogin = false
            return
        }
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
        guard LoginItemRegistrationPolicy.supportsCurrentProcess else {
            launchAtLogin = false
            return
        }
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
