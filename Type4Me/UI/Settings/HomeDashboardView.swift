import SwiftUI

/// Width-driven heatmap geometry. The grid keeps cells legible, then changes
/// the visible history window to consume the available horizontal space.
struct HomeHeatmapLayout: Equatable {
    let weekCount: Int
    let cellSize: CGFloat = 13
    let gap: CGFloat = 4

    init(width: CGFloat) {
        let usableWidth = max(0, width - 17)
        let cellSize: CGFloat = 13
        let gap: CGFloat = 4
        let columns = Int(floor((usableWidth + gap) / (cellSize + gap)))
        weekCount = max(12, min(104, columns))
    }

    /// Determines the heatmap activity level based on total characters dictacted,
    /// with a floor at Level 1 for any day with active sessions (even if 0 characters).
    static func activityLevel(characterCount: Int, recordCount: Int) -> Int {
        guard recordCount > 0 else { return 0 }
        switch characterCount {
        case ..<501:
            return 1
        case 501...2000:
            return 2
        case 2001...5000:
            return 3
        default:
            return 4
        }
    }
}

/// A compact landing dashboard: usage totals and activity stay visually
/// dominant, while configured mode shortcuts remain available at a glance.
struct HomeDashboardView: View {
    let isActive: Bool
    let openModesEditor: (UUID?) -> Void

    @Environment(AppState.self) private var appState
    @State private var statistics: HistoryStore.Statistics?
    @State private var activityDays: [HistoryStore.ActivityDay] = []
    @State private var hoveredHeatmapDay: HeatmapDay?
    @State private var visibleHeatmapDay: HeatmapDay?
    @State private var heatmapHoverGeneration = 0
    @State private var hoveredModeID: UUID?
    @State private var isModesButtonHovered = false

    private let historyStore = HistoryStore.shared
    private let assumedTypingSpeed = 40.0

    /// Use the same live source as the menu bar so edits and reordering are
    /// immediately reflected without waiting for persistence notifications.
    private var modes: [ProcessingMode] { appState.availableModes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    primaryColumn
                        .frame(minWidth: 350, maxWidth: .infinity)
                    shortcutsCard
                        .frame(width: 200)
                }

                VStack(alignment: .leading, spacing: 18) {
                    primaryColumn
                    shortcutsCard
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if isActive { refreshDashboard() }
        }
        .onChange(of: isActive) { _, isNowActive in
            if isNowActive { refreshDashboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            if isActive { refreshDashboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMode)) { _ in
            refreshDashboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modesDidChange)) { _ in
            refreshDashboard()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("说出想法，即刻成文", "Say it. Shape it."))
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.1)
                .foregroundStyle(TF.settingsText)

            Text(L("用你的声音完成写作，把时间留给更重要的事。",
                   "Turn your voice into polished text and save time for what matters."))
                .font(.system(size: 14))
                .foregroundStyle(TF.settingsTextTertiary)
        }
    }

    private var primaryColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            statisticsCard
            activityCard
        }
    }

    // MARK: - Usage overview

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                L("使用概览", "Usage overview"),
                subtitle: L("基于本机识别历史", "From on-device recognition history")
            )

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    metricTile(
                        icon: "clock",
                        title: L("输入总时间", "Total input time"),
                        value: formatDuration(statistics?.totalDuration ?? 0),
                        tint: TF.settingsAccentBlue
                    )
                    metricTile(
                        icon: "mic",
                        title: L("总字数", "Total characters"),
                        value: formatNumber(statistics?.totalCharacters ?? 0),
                        tint: Color(red: 0.45, green: 0.34, blue: 0.82)
                    )
                }
                GridRow {
                    metricTile(
                        icon: "hourglass",
                        title: L("估算节约时间", "Estimated time saved"),
                        value: formatDuration(estimatedSavedTime(statistics)),
                        tint: TF.settingsAccentGreen
                    )
                    metricTile(
                        icon: "bolt",
                        title: L("平均输入速度", "Average input speed"),
                        value: String(
                            format: L("%.0f 字/分", "%.0f chars/min"),
                            statistics?.averageSpeed ?? 0
                        ),
                        tint: TF.settingsAccentAmber
                    )
                }
            }
        }
        .padding(16)
        .dashboardCard()
    }

    private func metricTile(
        icon: String,
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.11))
                    )

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TF.settingsBg)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Activity

    private var activityCard: some View {
        let summary = HomeActivitySummary(activityDays: activityDays)
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle(L("活跃记录", "Activity"), subtitle: nil)

            HStack(spacing: 0) {
                activityStat(
                    value: summary.activeDays,
                    title: L("活跃天数", "Active days"),
                    alignment: .leading
                )
                activityStat(
                    value: summary.currentStreak,
                    title: L("当前连续", "Current streak"),
                    alignment: .center
                )
                activityStat(
                    value: summary.longestStreak,
                    title: L("最长连续", "Longest streak"),
                    alignment: .trailing
                )
            }

            heatmap

            HStack(spacing: 6) {
                Text(L("少", "Less"))
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatmapColor(level: level))
                        .frame(width: 12, height: 12)
                        .help(legendTooltip(for: level))
                        .accessibilityLabel(legendTooltip(for: level))
                }
                Text(L("多", "More"))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(TF.settingsTextTertiary)
        }
        .padding(16)
        .dashboardCard()
        .overlayPreferenceValue(HeatmapCellAnchorPreferenceKey.self) { anchors in
            GeometryReader { overlayProxy in
                if let day = visibleHeatmapDay, let anchor = anchors[day.id] {
                    heatmapTooltipOverlay(for: day, anchor: anchor, in: overlayProxy)
                }
            }
        }
        .zIndex(visibleHeatmapDay == nil ? 0 : 2)
    }

    private func activityStat(
        value: Int,
        title: String,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(TF.settingsText)
                Text(L("天", "days"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TF.settingsTextSecondary)
            }
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
        }
        .frame(
            maxWidth: .infinity,
            alignment: Alignment(horizontal: alignment, vertical: .center)
        )
        .accessibilityElement(children: .combine)
    }

    private var heatmap: some View {
        GeometryReader { proxy in
            let layout = HomeHeatmapLayout(width: proxy.size.width)
            let weeks = heatmapWeeks(weekCount: layout.weekCount)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L("最近 \(layout.weekCount) 周", "Last \(layout.weekCount) weeks"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Spacer(minLength: 0)
                }

                heatmapGrid(weeks: weeks, layout: layout)
                heatmapMonthLabels(weeks: weeks, layout: layout)
            }
        }
        .frame(height: 151)
    }

    private func heatmapGrid(
        weeks: [[HeatmapDay]],
        layout: HomeHeatmapLayout
    ) -> some View {
        let weekdayLabels = L("日一二三四五六", "SMTWTFS").map(String.init)
        return HStack(alignment: .top, spacing: 7) {
            VStack(spacing: layout.gap) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 10, height: layout.cellSize)
                }
            }

            HStack(spacing: layout.gap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: layout.gap) {
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(heatmapColor(level: activityLevel(characterCount: day.characterCount, recordCount: day.recordCount)))
                                .frame(width: layout.cellSize, height: layout.cellSize)
                                .accessibilityLabel(activityTooltip(for: day))
                                .onHover { isHovering in
                                    updateHeatmapHover(day, isHovering: isHovering)
                                }
                                .anchorPreference(
                                    key: HeatmapCellAnchorPreferenceKey.self,
                                    value: .bounds
                                ) { [day.id: $0] }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heatmapTooltipOverlay(
        for day: HeatmapDay,
        anchor: Anchor<CGRect>,
        in proxy: GeometryProxy
    ) -> some View {
        let cellRect = proxy[anchor]
        let tooltipWidth: CGFloat = 190
        let tooltipHeight: CGFloat = 96
        let minX = tooltipWidth / 2 + 4
        let maxX = max(minX, proxy.size.width - tooltipWidth / 2 - 4)
        let tooltipX = min(max(cellRect.midX, minX), maxX)
        let preferredTop = cellRect.minY - tooltipHeight - 8
        let tooltipY = preferredTop >= 0
            ? preferredTop + tooltipHeight / 2
            : cellRect.maxY + tooltipHeight / 2 + 8

        return heatmapTooltipCard(for: day)
            .frame(width: tooltipWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                TF.settingsCard,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(TF.settingsBorder, lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
            .position(x: tooltipX, y: tooltipY)
            .transition(.opacity)
            .zIndex(100)
            .allowsHitTesting(false)
    }

    private func updateHeatmapHover(_ day: HeatmapDay, isHovering: Bool) {
        guard !day.isFuture else {
            if hoveredHeatmapDay?.id == day.id {
                hoveredHeatmapDay = nil
            }
            visibleHeatmapDay = nil
            return
        }
        heatmapHoverGeneration += 1
        let generation = heatmapHoverGeneration
        let showDelay = 0.06
        let hideDelay = 0.12

        if isHovering {
            hoveredHeatmapDay = day
            DispatchQueue.main.asyncAfter(deadline: .now() + showDelay) {
                guard generation == heatmapHoverGeneration,
                      hoveredHeatmapDay?.id == day.id else { return }
                withAnimation(.easeIn(duration: 0.16)) {
                    visibleHeatmapDay = day
                }
            }
        } else {
            if hoveredHeatmapDay?.id == day.id {
                hoveredHeatmapDay = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay) {
                guard generation == heatmapHoverGeneration,
                      hoveredHeatmapDay == nil else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    visibleHeatmapDay = nil
                }
            }
        }
    }

    private func heatmapMonthLabels(
        weeks: [[HeatmapDay]],
        layout: HomeHeatmapLayout
    ) -> some View {
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: L("zh_CN", "en_US"))
        monthFormatter.dateFormat = L("M月", "MMM")
        let monthKeyFormatter = DateFormatter()
        monthKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthKeyFormatter.dateFormat = "yyyy-MM"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var markers: [HeatmapMonthMarker] = []

        for (weekIndex, week) in weeks.enumerated() {
            // Anchor each label to the column containing that month's first
            // day, rather than centering it across the whole month segment.
            if let firstOfMonth = week.first(where: {
                calendar.component(.day, from: $0.date) == 1
            }) {
                let key = monthKeyFormatter.string(from: firstOfMonth.date)
                markers.append(HeatmapMonthMarker(
                    id: key,
                    label: monthFormatter.string(from: firstOfMonth.date),
                    weekIndex: weekIndex
                ))
            }
        }

        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: 17, height: 12)
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(markers) { marker in
                        let centerX = CGFloat(marker.weekIndex) * (layout.cellSize + layout.gap)
                            + layout.cellSize / 2
                        Text(marker.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .position(x: centerX, y: 6)
                    }
                }
            }
        }
        .frame(height: 12)
    }

    // MARK: - Shortcuts

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("我的模式", "My Modes"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TF.settingsText)
                    Text(L("按模式快速输入", "Dictate by mode"))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }

                Spacer(minLength: 4)

                Button(action: { openModesEditor(nil) }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isModesButtonHovered ? Color.white : TF.settingsTextSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(isModesButtonHovered ? TF.settingsText : TF.settingsCardAlt))
                }
                .buttonStyle(.plain)
                .help(L("管理模式与快捷键", "Manage modes and shortcuts"))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isModesButtonHovered = hovering }
                }
            }
            .padding(15)

            Divider().padding(.horizontal, 15)

            if modes.isEmpty {
                Text(L("还没有模式", "No modes yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(modes.prefix(6).enumerated()), id: \.element.id) { index, mode in
                        shortcutRow(mode)
                        if index < min(modes.count, 6) - 1 {
                            Divider().padding(.leading, 15)
                        }
                    }

                    if modes.count > 6 {
                        Button(action: { openModesEditor(nil) }) {
                            Text(L("查看全部 \(modes.count) 个模式", "View all \(modes.count) modes"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(TF.settingsTextSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .dashboardCard()
    }

    private func shortcutRow(_ mode: ProcessingMode) -> some View {
        Button(action: { openModesEditor(mode.id) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(mode.localizedDisplayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    if mode.isBuiltin {
                        Circle()
                            .fill(TF.settingsAccentBlue.opacity(0.65))
                            .frame(width: 5, height: 5)
                            .help(L("内置模式", "Built-in mode"))
                    }
                }

                hotkeyBadge(mode)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(hoveredModeID == mode.id ? TF.settingsRowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("管理「\(mode.localizedDisplayName)」", "Manage \"\(mode.localizedDisplayName)\""))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { hoveredModeID = hovering ? mode.id : nil }
        }
    }

    @ViewBuilder
    private func hotkeyBadge(_ mode: ProcessingMode) -> some View {
        let bindings = mode.hotkeyBindings
        if bindings.isEmpty {
            Text(L("未设置", "Not set"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
        } else if bindings.count == 1 {
            hotkeyChip(bindings[0])
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach((1...bindings.count).reversed(), id: \.self) { count in
                    hotkeyRowCandidate(bindings: bindings, visibleCount: count)
                }
            }
        }
    }

    private func hotkeyRowCandidate(bindings: [HotkeyBinding], visibleCount: Int) -> some View {
        let visible = Array(bindings.prefix(visibleCount))
        let overflow = bindings.count - visibleCount

        return HStack(spacing: 5) {
            ForEach(visible) { binding in
                hotkeyChip(binding)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(TF.settingsTextSecondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hotkeyChip(_ binding: HotkeyBinding) -> some View {
        let accent = hotkeyStyleColor(binding.style)
        let key = HotkeyRecorderView.keyDisplayName(keyCode: binding.keyCode, modifiers: binding.modifiers)
        return HStack(spacing: 4) {
            Image(systemName: hotkeyStyleIcon(binding.style))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent)

            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .help(hotkeyChipTooltip(binding))
    }

    private func hotkeyChipTooltip(_ binding: HotkeyBinding) -> String {
        let key = HotkeyRecorderView.keyDisplayName(
            keyCode: binding.keyCode, modifiers: binding.modifiers)
        return "\(key) · \(hotkeyStyleLabel(binding.style))"
    }

    private func hotkeyStyleIcon(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold:
            return "hand.tap.fill"
        case .toggle:
            return "arrow.triangle.2.circlepath"
        }
    }

    private func hotkeyStyleColor(_ style: ProcessingMode.HotkeyStyle) -> Color {
        switch style {
        case .hold:
            return Color(red: 0.20, green: 0.60, blue: 0.86)
        case .toggle:
            return Color(red: 0.36, green: 0.56, blue: 0.32)
        }
    }

    // MARK: - Formatting and data

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(TF.settingsText)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
        }
    }

    private func refreshDashboard() {
        Task {
            async let newStatistics = historyStore.getStatistics()
            async let newActivityDays = historyStore.getActivityDays()
            statistics = await newStatistics
            activityDays = await newActivityDays
        }
    }

    private func estimatedSavedTime(_ stats: HistoryStore.Statistics?) -> Double {
        guard let stats else { return 0 }
        let estimatedTypingSeconds = Double(stats.totalCharacters) / assumedTypingSpeed * 60
        return max(0, estimatedTypingSeconds - stats.totalDuration)
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds <= 0 { return L("0 分钟", "0 min") }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 1 { return L("< 1 分钟", "< 1 min") }
        if totalMinutes < 60 { return L("\(totalMinutes) 分钟", "\(totalMinutes) min") }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? L("\(hours) 小时", "\(hours) hr")
            : L("\(hours) 小时 \(minutes) 分", "\(hours) hr \(minutes) min")
    }

    private func formatNumber(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func hotkeyStyleLabel(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold: return L("按住录制", "Hold")
        case .toggle: return L("按下切换", "Toggle")
        }
    }

    private func heatmapWeeks(weekCount: Int) -> [[HeatmapDay]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let daysSinceSunday = calendar.component(.weekday, from: today) - 1
        let currentWeekStart = calendar.date(byAdding: .day, value: -daysSinceSunday, to: today) ?? today
        let firstWeekStart = calendar.date(
            byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart
        ) ?? currentWeekStart
        let activityByDay = Dictionary(uniqueKeysWithValues: activityDays.map {
            ($0.dayIdentifier, $0)
        })
        let formatter = dayIdentifierFormatter(calendar: calendar)

        return (0..<weekCount).map { weekOffset in
            (0..<7).map { weekdayOffset in
                let offset = weekOffset * 7 + weekdayOffset
                let date = calendar.date(byAdding: .day, value: offset, to: firstWeekStart) ?? firstWeekStart
                let identifier = formatter.string(from: date)
                let isFuture = date > today
                let activity = activityByDay[identifier]
                return HeatmapDay(
                    date: date,
                    recordCount: isFuture ? 0 : (activity?.recordCount ?? 0),
                    durationSeconds: isFuture ? 0 : (activity?.durationSeconds ?? 0),
                    characterCount: isFuture ? 0 : (activity?.characterCount ?? 0),
                    isFuture: isFuture
                )
            }
        }
    }

    private func activityLevel(characterCount: Int, recordCount: Int) -> Int {
        HomeHeatmapLayout.activityLevel(characterCount: characterCount, recordCount: recordCount)
    }

    private func heatmapColor(level: Int) -> Color {
        switch level {
        case 1: return TF.settingsAccentBlue.opacity(0.18)
        case 2: return TF.settingsAccentBlue.opacity(0.36)
        case 3: return TF.settingsAccentBlue.opacity(0.58)
        case 4: return TF.settingsAccentBlue.opacity(0.90)
        default: return TF.settingsCardAlt
        }
    }

    private func legendTooltip(for level: Int) -> String {
        switch level {
        case 0:
            return L("0 字", "0 characters")
        case 1:
            return L("1 ~ 500 字", "1 – 500 characters")
        case 2:
            return L("501 ~ 2,000 字", "501 – 2,000 characters")
        case 3:
            return L("2,001 ~ 5,000 字", "2,001 – 5,000 characters")
        default:
            return L("5,000+ 字", "5,000+ characters")
        }
    }

    private func activityTooltip(for day: HeatmapDay) -> String {
        let date = activityDateLabel(for: day.date)
        if day.isFuture { return date }
        return L(
            "\(date)\n听写时长：\(formatDuration(day.durationSeconds))\n字数：\(formatNumber(day.characterCount))",
            "\(date)\nDictation time: \(formatDuration(day.durationSeconds))\nCharacters: \(formatNumber(day.characterCount))"
        )
    }

    private func heatmapTooltipCard(for day: HeatmapDay) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(activityDateLabel(for: day.date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TF.settingsText)

            heatmapTooltipDetail(
                icon: "clock",
                label: L("听写时长", "Dictation time"),
                value: formatDuration(day.durationSeconds)
            )
            heatmapTooltipDetail(
                icon: "text.word.spacing",
                label: L("字数", "Characters"),
                value: formatNumber(day.characterCount)
            )
        }
        .padding(13)
        .frame(minWidth: 180, alignment: .leading)
    }

    private func heatmapTooltipDetail(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsAccentBlue)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsText)
                .layoutPriority(1)
        }
    }

    private func activityDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L("zh_CN", "en_US"))
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func dayIdentifierFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private struct HeatmapDay: Identifiable {
        let date: Date
        let recordCount: Int
        let durationSeconds: Double
        let characterCount: Int
        let isFuture: Bool
        var id: Date { date }
    }

    private struct HeatmapCellAnchorPreferenceKey: PreferenceKey {
        static var defaultValue: [Date: Anchor<CGRect>] = [:]

        static func reduce(
            value: inout [Date: Anchor<CGRect>],
            nextValue: () -> [Date: Anchor<CGRect>]
        ) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private struct HeatmapMonthMarker: Identifiable {
        let id: String
        let label: String
        let weekIndex: Int
    }
}

/// Pure summary logic kept separate from SwiftUI so streak behavior is easy to
/// validate and remains deterministic at local calendar-day boundaries.
struct HomeActivitySummary: Equatable {
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int

    init(
        activityDays: [HistoryStore.ActivityDay],
        today: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputCalendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let activeDates = Set(activityDays.lazy.filter { $0.recordCount > 0 }.compactMap {
            formatter.date(from: $0.dayIdentifier).map(calendar.startOfDay(for:))
        })
        activeDays = activeDates.count

        let sortedDates = activeDates.sorted()
        var longest = 0
        var running = 0
        var previous: Date?
        for date in sortedDates {
            if let previous,
               calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                running += 1
            } else {
                running = 1
            }
            longest = max(longest, running)
            previous = date
        }
        longestStreak = longest

        let localToday = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: localToday) ?? localToday
        var cursor: Date?
        if activeDates.contains(localToday) {
            cursor = localToday
        } else if activeDates.contains(yesterday) {
            cursor = yesterday
        } else {
            cursor = nil
        }

        var current = 0
        while let day = cursor, activeDates.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        currentStreak = current
    }
}

private extension View {
    func dashboardCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TF.settingsCard)
                .shadow(color: Color.black.opacity(0.035), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }
}

/// A very light perspective dot field used only behind the Home dashboard.
struct HomeDottedWaveBackground: View {
    var body: some View {
        Canvas { context, size in
            let projectedX: CGFloat = 7.8
            let projectedY: CGFloat = 7.2
            let originX = size.width * 0.50
            let originY = size.height * 0.48
            let indexRadius = Int(ceil(
                size.width / (projectedX * 2) + size.height / (projectedY * 2)
            )) + 8
            let waveCenterX = size.width * 0.68
            let waveCenterY = size.height * 0.63
            let scaleX = max(size.width * 0.58, 1)
            let scaleY = max(size.height * 0.64, 1)

            for u in -indexRadius...indexRadius {
                for v in -indexRadius...indexRadius {
                    let baseX = originX + CGFloat(u - v) * projectedX
                    let baseY = originY + CGFloat(u + v) * projectedY
                    guard baseX > -12, baseX < size.width + 12,
                          baseY > -44, baseY < size.height + 18 else { continue }

                    let nx = (baseX - waveCenterX) / scaleX
                    let ny = (baseY - waveCenterY) / scaleY
                    let envelope = exp(-(nx * nx * 0.82 + ny * ny * 1.05))
                    let wave = sin(nx * 6.2 + ny * 1.4)
                        * cos(ny * 2.3 - nx * 0.55)
                        * envelope
                    let x = baseX - wave * 5.5
                    let y = baseY - wave * 46
                    let nearFactor = 0.72
                        + min(max(baseY / max(size.height, 1), 0), 1) * 0.28
                    let crest = (wave + envelope + 1) / 3
                    let radius = (0.78 + crest * 0.52) * nearFactor
                    let opacity = (0.055 + envelope * (0.018 + crest * 0.04)) * nearFactor
                    let dot = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(Color.black.opacity(opacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
