import AppKit
import SwiftUI

struct AgentInboxView: View {
    @ObservedObject var store: AgentInboxStore
    @ObservedObject var model: AgentInboxViewModel
    var layout = AgentInboxPanelLayout()
    let onClose: () -> Void
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @State private var measurements: [AgentInboxMeasuredElement: CGFloat] = [:]
    @AppStorage("tf_language") private var languageRaw = AppLanguage.systemDefault
    @AppStorage(SettingsTheme.storageKey) private var themeRaw = SettingsTheme.defaultValue.rawValue

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .en }
    private var theme: SettingsTheme { SettingsTheme.resolve(themeRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.measuringInboxHeight(.header)
            if store.configurationError {
                Text(copy(.monitoringUnavailable))
                    .font(.system(size: 12)).foregroundStyle(TF.settingsAccentAmber)
                    .padding(.horizontal, TF.spacingLG).padding(.bottom, TF.spacingMD)
                    .fixedSize(horizontal: false, vertical: true)
                    .measuringInboxHeight(.warning)
            }
            if store.items.isEmpty {
                ScrollView {
                    emptyState.measuringInboxHeight(.empty)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ScrollView {
                    VStack(spacing: layout.rowSpacing) {
                        // Keep the measured prefix mounted even while the rest of the queue scrolls.
                        ForEach(Array(store.items.prefix(layout.maximumVisibleItems))) { item in
                            row(item, measured: true)
                        }
                        if store.items.count > layout.maximumVisibleItems {
                            LazyVStack(spacing: layout.rowSpacing) {
                                ForEach(Array(store.items.dropFirst(layout.maximumVisibleItems))) { item in
                                    row(item, measured: false)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, TF.spacingLG)
                }
                .padding(.bottom, layout.listBottomInset)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TF.settingsBg)
        .clipShape(RoundedRectangle(cornerRadius: TF.cornerLG))
        .overlay(RoundedRectangle(cornerRadius: TF.cornerLG).stroke(TF.settingsBorder, lineWidth: 1))
        .foregroundStyle(TF.settingsText)
        .preferredColorScheme(theme.colorScheme)
        .environment(\.locale, Locale(identifier: language == .zh ? "zh_CN" : "en_US"))
        .background(AgentInboxWindowAppearance(theme: theme, title: copy(.title)))
        .onPreferenceChange(AgentInboxHeightPreference.self) { measurements in
            self.measurements = measurements
            onContentHeightChange(layout.contentHeight(itemIDs: store.items.map(\.id), measurements: measurements))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: TF.spacingMD) {
            HStack(spacing: TF.spacingSM) {
                Text(copy(.title)).font(.system(size: 19, weight: .semibold))
                let summary = AgentInboxSummary(items: store.items)
                if summary.count > 0 {
                    Text(summary.countText)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, TF.spacingSM).padding(.vertical, TF.spacingXS)
                        .background(TF.settingsCardAlt, in: Capsule())
                        .accessibilityLabel(summary.accessibilityLabel(language: language))
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(TF.settingsControl, in: RoundedRectangle(cornerRadius: TF.cornerSM))
            }
            .buttonStyle(.plain).help(copy(.close)).accessibilityLabel(copy(.close))
            .focusEffectDisabled()
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(TF.spacingLG)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: TF.spacingMD) {
            Image(systemName: "tray").font(.system(size: 25, weight: .light))
                .foregroundStyle(TF.settingsTextTertiary).accessibilityHidden(true)
            Text(copy(.emptyTitle)).font(.system(size: 16, weight: .medium))
            Text(copy(.emptyDetail)).font(.system(size: 13))
                .foregroundStyle(TF.settingsTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(TF.spacingXL)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Builds a native-session row with intrinsic height for the current language and width.
    ///
    /// Args:
    ///   item: Queue snapshot, already ordered by user attention and activity time.
    ///   measured: Whether this row belongs to the measured prefix of the queue.
    ///
    /// Returns:
    ///   A naturally sized row whose navigation leaves the queue visible.
    private func row(_ item: AgentInboxItem, measured: Bool) -> some View {
        AgentInboxRow(
            item: item, language: language,
            minimumHeight: layout.minimumRowHeight(itemIDs: store.items.map(\.id), measurements: measurements),
            measured: measured,
            isOpening: model.openingID == item.id,
            isBusy: model.openingID != nil,
            failure: model.failedID == item.id ? model.failure : nil,
            onOpen: { Task { await model.open(item) } },
            onDismiss: { store.dismiss(item.id) }
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Resolves semantic UI text whenever the persistent panel is rendered.
    ///
    /// Args:
    ///   label: Label to render in the current interface language.
    ///
    /// Returns:
    ///   Display-only translated text.
    private func copy(_ label: AgentInboxCopy.Label) -> String {
        AgentInboxCopy.text(label, language: language)
    }
}

private struct AgentInboxRow: View {
    let item: AgentInboxItem
    let language: AppLanguage
    let minimumHeight: CGFloat
    let measured: Bool
    let isOpening: Bool
    let isBusy: Bool
    let failure: AgentInboxCopy.Label?
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: TF.spacingSM) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: TF.spacingSM) {
                    HStack(alignment: .firstTextBaseline, spacing: TF.spacingSM) {
                        if item.isUnread {
                            Circle().fill(TF.settingsAccentAmber).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(AgentSessionDescriptor.displayTitle(item.session.title, language: language))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsTextTertiary).accessibilityHidden(true)
                    }
                    HStack(spacing: TF.spacingSM) {
                        Text(item.session.application.displayName)
                            .foregroundStyle(TF.settingsTextSecondary)
                        Spacer(minLength: 0)
                        Text(item.updatedAt, style: .relative).foregroundStyle(TF.settingsTextTertiary)
                    }
                    .font(.system(size: 11))
                    let statusLayout = item.status == .unknown
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: TF.spacingXS))
                        : AnyLayout(HStackLayout(spacing: TF.spacingSM))
                    statusLayout {
                        ForEach(AgentInboxCopy.statusLabels(for: item), id: \.self) { label in
                            Label(copy(label), systemImage: icon(label))
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(color(label))
                        }
                    }
                    let detail = item.pendingRequests.first(where: { !$0.text.isEmpty })?.text ?? item.preview
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 13)).lineLimit(3)
                            .foregroundStyle(TF.settingsTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isOpening {
                        Text(copy(.opening)).font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
                    } else if !item.session.canOpenExistingConversation {
                        Text(copy(.cannotOpen)).font(.system(size: 11)).foregroundStyle(TF.settingsTextTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(isBusy || !item.session.canOpenExistingConversation)
            .help(copy(.open))
            .accessibilityLabel(AgentInboxCopy.accessibilityLabel(for: item, language: language))
            .accessibilityHint(copy(.open))
            if let failure {
                Text(copy(failure)).font(.system(size: 12)).foregroundStyle(TF.settingsAccentRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TF.spacingMD)
        .fixedSize(horizontal: false, vertical: true)
        .measuringInboxHeight(measured ? .row(item.id) : nil)
        .frame(minHeight: minimumHeight, alignment: .topLeading)
        .background(hovered ? TF.settingsRowHover : TF.settingsCard,
                    in: RoundedRectangle(cornerRadius: TF.cornerMD))
        .overlay(RoundedRectangle(cornerRadius: TF.cornerMD).stroke(TF.settingsBorder, lineWidth: 1))
        .onHover { hovered = $0 }
        .contextMenu {
            Button(copy(.dismiss), action: onDismiss).help(copy(.dismissHint))
        }
    }

    /// Translates interface copy while preserving the native message body.
    ///
    /// Args:
    ///   label: Stable UI label.
    ///
    /// Returns:
    ///   Localized copy.
    private func copy(_ label: AgentInboxCopy.Label) -> String {
        AgentInboxCopy.text(label, language: language)
    }

    /// Selects restrained status accents from the existing settings palette.
    ///
    /// Args:
    ///   label: Current semantic status label.
    ///
    /// Returns:
    ///   A theme-aware MyType color.
    private func color(_ label: AgentInboxCopy.Label) -> Color {
        switch label {
        case .completed: TF.settingsAccentGreen
        case .input, .approval, .waiting: TF.settingsAccentAmber
        case .failed: TF.settingsAccentRed
        default: TF.settingsTextSecondary
        }
    }

    /// Pairs each status with a static accessible symbol, without ongoing animation.
    ///
    /// Args:
    ///   label: Current semantic status label.
    ///
    /// Returns:
    ///   An SF Symbols name.
    private func icon(_ label: AgentInboxCopy.Label) -> String {
        switch label {
        case .completed: "checkmark.circle.fill"
        case .input: "bubble.left"
        case .approval: "hand.raised"
        case .running: "circle.dotted"
        case .waiting: "clock"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        default: "circle"
        }
    }
}

private struct AgentInboxWindowAppearance: NSViewRepresentable {
    let theme: SettingsTheme
    let title: String

    /// Creates an invisible bridge for live window title and theme changes.
    ///
    /// Args:
    ///   context: SwiftUI host context.
    ///
    /// Returns:
    ///   The appearance observer attached to the persistent panel.
    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.theme = theme
        view.title = title
        return view
    }

    /// Applies language and theme changes to an already visible panel.
    ///
    /// Args:
    ///   nsView: Attached appearance observer.
    ///   context: SwiftUI host context.
    func updateNSView(_ nsView: AppearanceView, context: Context) {
        nsView.theme = theme
        nsView.title = title
    }

    final class AppearanceView: NSView {
        var theme = SettingsTheme.defaultValue { didSet { window?.appearance = theme.appearance } }
        var title = "" { didSet { window?.title = title } }
        /// Updates AppKit after the observer joins its native window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = theme.appearance
            window?.title = title
        }
    }
}

/// Aggregates intrinsic heights without coupling SwiftUI layout to native window dimensions.
private struct AgentInboxHeightPreference: PreferenceKey {
    static let defaultValue: [AgentInboxMeasuredElement: CGFloat] = [:]

    /// Combines current header, warning, empty state, and leading row measurements.
    ///
    /// Args:
    ///   value: Measurements already collected in this render pass.
    ///   nextValue: Measurements reported by another content element.
    static func reduce(value: inout [AgentInboxMeasuredElement: CGFloat],
                       nextValue: () -> [AgentInboxMeasuredElement: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    /// Reports natural content height without adding a layout constraint or visible element.
    ///
    /// Args:
    ///   element: Stable identity, or nil for lazy rows outside the measured prefix.
    ///
    /// Returns:
    ///   The original view with a noninteractive geometry reader in its background.
    func measuringInboxHeight(_ element: AgentInboxMeasuredElement?) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: AgentInboxHeightPreference.self,
                                   value: element.map { [$0: geometry.size.height] } ?? [:])
        })
    }
}
