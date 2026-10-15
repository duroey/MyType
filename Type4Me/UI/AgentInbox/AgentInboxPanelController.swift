import AppKit
import Combine
import SwiftUI

enum AgentInboxPresentation: Equatable {
    case userRequested
    case taskCompleted
    case needsResponse

    var requestsKeyboardFocus: Bool { self == .userRequested }

    /// Hides an automatic notification only after every reason to keep reading is cleared.
    ///
    /// Args:
    ///   items: Complete current queue after a store mutation has finished.
    ///   configurationError: Whether invalid configuration prevents live monitoring.
    ///   isOpening: Whether native navigation is in progress.
    ///   hasOpenFailure: Whether the user needs to see a navigation error.
    ///
    /// Returns:
    ///   True for a quiet automatic panel; manually opened panels always stay visible.
    func shouldHideWhenQuiet(
        items: [AgentInboxItem], configurationError: Bool = false,
        isOpening: Bool = false, hasOpenFailure: Bool = false
    ) -> Bool {
        self != .userRequested && !configurationError && !isOpening && !hasOpenFailure
            && !items.contains(where: \.needsAttention)
    }
}

/// Shared sizing configuration for the native panel and its measured SwiftUI content.
struct AgentInboxPanelLayout {
    var preferredWidth: CGFloat = 420
    var minimumSize = NSSize(width: 320, height: 180)
    var resizeEdgeWidth: CGFloat = 6
    var resizeCornerLength: CGFloat = 12
    var maximumVisibleItems = 3
    var estimatedHeaderHeight: CGFloat = 88
    var estimatedRowHeight: CGFloat = 160
    var estimatedEmptyHeight: CGFloat = 144
    var screenInset: CGFloat = TF.spacingLG
    var rowSpacing: CGFloat = TF.spacingSM
    var listBottomInset: CGFloat = TF.spacingLG

    /// Fits the current content while capping the viewport at the first three rows.
    ///
    /// Args:
    ///   itemIDs: Queue identities in their current presentation order.
    ///   measurements: Intrinsic heights from the current language, width, and row content.
    ///
    /// Returns:
    ///   The desired panel height before clamping to the available display area.
    func contentHeight(itemIDs: [String], measurements: [AgentInboxMeasuredElement: CGFloat]) -> CGFloat {
        let header = measurements[.header] ?? estimatedHeaderHeight
        let warning = measurements[.warning] ?? 0
        guard !itemIDs.isEmpty else {
            return ceil(header + warning + (measurements[.empty] ?? estimatedEmptyHeight))
        }
        let visibleIDs = itemIDs.prefix(max(1, maximumVisibleItems))
        let rows = CGFloat(visibleIDs.count) * minimumRowHeight(itemIDs: itemIDs, measurements: measurements)
        return ceil(header + warning + rows + CGFloat(max(0, visibleIDs.count - 1)) * rowSpacing + listBottomInset)
    }

    /// Gives every row enough space to prevent shorter later cards exceeding the three-row limit.
    ///
    /// Args:
    ///   itemIDs: Ordered queue identities, with only the visible prefix used for sizing.
    ///   measurements: Natural content heights measured before applying the minimum row height.
    ///
    /// Returns:
    ///   The tallest natural height in the visible prefix; longer later rows remain unconstrained.
    func minimumRowHeight(itemIDs: [String], measurements: [AgentInboxMeasuredElement: CGFloat]) -> CGFloat {
        itemIDs.prefix(max(1, maximumVisibleItems)).map { measurements[.row($0)] ?? estimatedRowHeight }.max()
            ?? estimatedRowHeight
    }

    /// Keeps the panel's top edge anchored when its measured content grows or shrinks.
    ///
    /// Args:
    ///   contentHeight: Measured content height, including header and list padding.
    ///   visibleFrame: Usable display area, excluding the menu bar and Dock.
    ///   currentFrame: Existing visible panel bounds, or nil for initial presentation.
    ///   preferredSize: User-selected size, which takes priority over measured content.
    ///
    /// Returns:
    ///   A display-bounded frame anchored to the current or default upper-right corner.
    func frame(
        contentHeight: CGFloat, visibleFrame: NSRect, currentFrame: NSRect? = nil,
        preferredSize: NSSize? = nil
    ) -> NSRect {
        let desiredSize = preferredSize ?? NSSize(width: preferredWidth, height: contentHeight)
        // Automatic notifications keep their margin; an explicit resize may fill the usable display.
        let inset = preferredSize == nil ? screenInset : 0
        let width = min(max(minimumSize.width, desiredSize.width), max(0, visibleFrame.width - inset * 2))
        let height = min(max(minimumSize.height, desiredSize.height), max(0, visibleFrame.height - inset * 2))
        let right = min(max(currentFrame?.maxX ?? visibleFrame.maxX - screenInset,
                            visibleFrame.minX + inset + width), visibleFrame.maxX - inset)
        let top = min(max(currentFrame?.maxY ?? visibleFrame.maxY - screenInset,
                          visibleFrame.minY + inset + height), visibleFrame.maxY - inset)
        return NSRect(x: right - width, y: top - height, width: width, height: height)
    }
}

enum AgentInboxMeasuredElement: Hashable {
    case header, warning, empty
    case row(String)
}

@MainActor
private final class AgentInboxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Supplies ordinary resize cursors even when the floating borderless panel is not key.
@MainActor
private final class AgentInboxHostingView: NSHostingView<AgentInboxView> {
    var resizeLayout = AgentInboxPanelLayout()
    private var resizeTrackingAreas: [NSTrackingArea] = []
    private var currentResizeCursor: NSCursor?
    private let backgroundCursor = AgentInboxBackgroundCursor()

    private enum Edge {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch self {
                case .top: position = .top
                case .bottom: position = .bottom
                case .left: position = .left
                case .right: position = .right
                case .topLeft: position = .topLeft
                case .topRight: position = .topRight
                case .bottomLeft: position = .bottomLeft
                case .bottomRight: position = .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            switch self {
            case .top, .bottom: return .resizeUpDown
            default: return .resizeLeftRight
            }
        }
    }

    /// Registers narrow cursor regions while leaving resizing and all hit testing to AppKit.
    override func resetCursorRects() {
        super.resetCursorRects()
        for region in resizeRegions() { addCursorRect(region.rect, cursor: region.edge.cursor) }
    }

    /// Refreshes non-key-window cursor tracking whenever the panel's bounds change.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resizeTrackingAreas.forEach(removeTrackingArea)
        resizeTrackingAreas = resizeRegions().flatMap { region in
            [
                NSTrackingArea(
                    rect: region.rect, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
                    owner: self, userInfo: nil
                ),
                NSTrackingArea(
                    rect: region.rect, options: [.activeInKeyWindow, .cursorUpdate],
                    owner: self, userInfo: nil
                )
            ]
        }
        resizeTrackingAreas.forEach(addTrackingArea)
    }

    /// Shows only the system resize cursor over a native resizing edge or corner.
    ///
    /// Args:
    ///   event: Cursor update generated by a perimeter tracking area.
    override func cursorUpdate(with event: NSEvent) {
        if !updateResizeCursor(at: convert(event.locationInWindow, from: nil)) {
            super.cursorUpdate(with: event)
        }
    }

    /// Handles perimeter entry without requiring the floating panel to activate.
    ///
    /// Args:
    ///   event: Mouse entry delivered to this view's tracking region.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard resizeTrackingAreas.contains(where: { $0 === event.trackingArea }) else { return }
        updateResizeCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Keeps ordinary resize feedback current while forwarding movement to the hosting view.
    ///
    /// Args:
    ///   event: Mouse movement within a narrow perimeter tracking region.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateResizeCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Releases only this view's cursor when leaving the perimeter or entering its content.
    ///
    /// Args:
    ///   event: Mouse exit delivered to this view's tracking region.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard resizeTrackingAreas.contains(where: { $0 === event.trackingArea }) else { return }
        // AppKit can synthesize exits while rebuilding tracking areas after resizing.
        guard let window else { releaseResizeCursor(); return }
        updateResizeCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Releases cursor ownership when the queue hides or its hosting view is detached.
    func releaseResizeCursor() {
        if let cursor = currentResizeCursor, NSCursor.current == cursor { NSCursor.arrow.set() }
        currentResizeCursor = nil
        backgroundCursor.end()
    }

    /// Restores background cursor policy before AppKit disconnects the hosting view.
    ///
    /// Args:
    ///   newWindow: Destination window, or nil when the view is being removed.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { releaseResizeCursor() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Sets a system resize cursor or releases it without overwriting a cursor set by content.
    ///
    /// Args:
    ///   point: Current pointer location in this view's coordinates.
    ///
    /// Returns:
    ///   Whether the pointer is over a resizing region.
    @discardableResult
    private func updateResizeCursor(at point: NSPoint) -> Bool {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              let region = resizeRegions().first(where: { $0.rect.contains(point) }) else {
            releaseResizeCursor()
            return false
        }
        backgroundCursor.begin()
        let cursor = region.edge.cursor
        cursor.set()
        currentResizeCursor = cursor
        return true
    }

    /// Describes disjoint edge and corner regions without adding visible handles or overlays.
    ///
    /// Returns:
    ///   Resize cursor regions in local coordinates, respecting the hosting view's flipped axis.
    private func resizeRegions() -> [(rect: NSRect, edge: Edge)] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let edge = min(resizeLayout.resizeEdgeWidth, min(bounds.width, bounds.height) / 2)
        let corner = min(resizeLayout.resizeCornerLength, min(bounds.width, bounds.height) / 2)
        let topY = isFlipped ? bounds.minY : bounds.maxY - edge
        let bottomY = isFlipped ? bounds.maxY - edge : bounds.minY
        let topCornerY = isFlipped ? bounds.minY : bounds.maxY - corner
        let bottomCornerY = isFlipped ? bounds.maxY - corner : bounds.minY
        return [
            (NSRect(x: bounds.minX + corner, y: topY, width: bounds.width - corner * 2, height: edge), .top),
            (NSRect(x: bounds.minX + corner, y: bottomY, width: bounds.width - corner * 2, height: edge), .bottom),
            (NSRect(x: bounds.minX, y: bounds.minY + corner, width: edge, height: bounds.height - corner * 2), .left),
            (NSRect(x: bounds.maxX - edge, y: bounds.minY + corner, width: edge, height: bounds.height - corner * 2), .right),
            (NSRect(x: bounds.minX, y: topCornerY, width: corner, height: corner), .topLeft),
            (NSRect(x: bounds.maxX - corner, y: topCornerY, width: corner, height: corner), .topRight),
            (NSRect(x: bounds.minX, y: bottomCornerY, width: corner, height: corner), .bottomLeft),
            (NSRect(x: bounds.maxX - corner, y: bottomCornerY, width: corner, height: corner), .bottomRight)
        ]
    }
}

@MainActor
final class AgentInboxPanelController: NSObject, NSWindowDelegate {
    static let shared = AgentInboxPanelController()
    private static let preferredSizeKey = "tf_agentInboxPanelSize"

    private let layout: AgentInboxPanelLayout
    private let defaults: UserDefaults
    private let storeProvider: @MainActor () -> AgentInboxStore
    private let presentOverride: ((AgentInboxPresentation) -> Void)?
    private let dismissOverride: (() -> Void)?
    private var panel: AgentInboxPanel?
    private var model: AgentInboxViewModel?
    private var contentHeight: CGFloat?
    private var preferredSize: NSSize?
    private var liveResizeStartSize: NSSize?
    private var storeObserver: AnyCancellable?
    private var navigationObserver: AnyCancellable?
    private(set) var presentation: AgentInboxPresentation?

    /// Creates a persistent queue without a window, timers, or global interaction observers.
    ///
    /// Args:
    ///   layout: Shared content sizing and screen margins.
    ///   defaults: Stores only the size explicitly selected by dragging the panel.
    ///   storeProvider: Supplies the shared inbox only when native presentation needs it.
    ///   present: Optional window-free presentation observer for isolated checks.
    ///   dismiss: Optional window-free counterpart for explicit dismissal.
    init(
        layout: AgentInboxPanelLayout = AgentInboxPanelLayout(),
        defaults: UserDefaults = .standard,
        storeProvider: @escaping @MainActor () -> AgentInboxStore = { AgentInboxStore.shared },
        present: ((AgentInboxPresentation) -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) {
        self.layout = layout
        self.defaults = defaults
        self.storeProvider = storeProvider
        presentOverride = present
        dismissOverride = dismiss
        super.init()
    }

    /// Opens the persistent queue from its menu entry, allowing keyboard interaction.
    func show() {
        present(.userRequested)
    }

    /// Shows a fresh completion without taking focus from the user's current work.
    ///
    /// Args:
    ///   item: Verified completed session snapshot after store deduplication.
    func showCompletion(_ item: AgentInboxItem) {
        guard item.status == .completed else { return }
        present(.taskCompleted)
    }

    /// Shows an unresolved question or approval without taking keyboard focus.
    ///
    /// Args:
    ///   item: Current queue snapshot containing a native pending request.
    func showRequest(_ item: AgentInboxItem) {
        guard !item.pendingRequests.isEmpty else { return }
        present(.needsResponse)
    }

    /// Hides the queue without modifying stored native state or pending requests.
    func close() {
        presentation = nil
        model?.resetPresentation()
        (panel?.contentView as? AgentInboxHostingView)?.releaseResizeCursor()
        if let dismissOverride { dismissOverride() } else { panel?.orderOut(nil) }
    }

    /// Releases the panel during application shutdown without consuming messages.
    func stop() {
        storeObserver = nil
        navigationObserver = nil
        close()
        panel?.delegate = nil
        panel?.contentView = nil
        panel = nil
        model = nil
        contentHeight = nil
        liveResizeStartSize = nil
    }

    /// Presents attention updates automatically, or keeps a manually opened queue visible.
    ///
    /// Args:
    ///   reason: Only a manual reveal may request keyboard focus.
    private func present(_ reason: AgentInboxPresentation) {
        if presentation != .userRequested { presentation = reason }
        observeStoreIfNeeded()
        if let presentOverride {
            presentOverride(reason)
            return
        }
        if panel == nil { createPanel() }
        guard let panel else { return }
        resizeToContent()
        if reason.requestsKeyboardFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Hosts the existing MyType style and leaves the queue visible after native navigation.
    private func createPanel() {
        let store = storeProvider()
        let model = AgentInboxViewModel(markRead: { [weak store] selected in
            store?.acknowledgeOpened(selected)
        })
        let panel = AgentInboxPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        // Match the dictation overlay while preserving manual-only keyboard focus.
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        preferredSize = loadPreferredSize()
        self.model = model
        self.panel = panel
        navigationObserver = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileVisibility() }
        contentHeight = layout.contentHeight(itemIDs: store.items.map(\.id), measurements: [:])
        let hosting = AgentInboxHostingView(rootView: AgentInboxView(
            store: store, model: model, layout: layout,
            onClose: { [weak self] in self?.close() },
            onContentHeightChange: { [weak self] height in
                guard let self, height.isFinite, height > 0, self.contentHeight != height else { return }
                self.contentHeight = height
                self.resizeToContent()
            }
        ))
        hosting.resizeLayout = layout
        // The panel owns its bounds; intrinsic SwiftUI sizes must not undo a user's resize.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    /// Records native resize gestures without turning automatic layout into a saved preference.
    ///
    /// Args:
    ///   notification: AppKit notification for the panel starting a live resize.
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let panel, (notification.object as? NSWindow) === panel else { return }
        liveResizeStartSize = panel.frame.size
    }

    /// Keeps the user's final dimensions across incoming messages, reopening, and app restarts.
    ///
    /// Args:
    ///   notification: AppKit notification after the user releases a resize edge or corner.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, (notification.object as? NSWindow) === panel else { return }
        defer { liveResizeStartSize = nil }
        guard let startSize = liveResizeStartSize, panel.frame.size != startSize else { return }
        preferredSize = panel.frame.size
        defaults.set([
            "width": Double(panel.frame.width), "height": Double(panel.frame.height)
        ], forKey: Self.preferredSizeKey)
        // AppKit still reports inLiveResize during this notification; clamp position after it ends.
        DispatchQueue.main.async { [weak self] in self?.resizeToContent() }
    }

    /// Reapplies display bounds when the queue moves to a different screen.
    ///
    /// Args:
    ///   notification: AppKit notification identifying the panel whose display changed.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let panel, (notification.object as? NSWindow) === panel else { return }
        resizeToContent()
    }

    /// Reads valid saved dimensions while preserving automatic sizing on first use.
    ///
    /// Returns:
    ///   Positive finite dimensions, or nil when no usable user preference exists.
    private func loadPreferredSize() -> NSSize? {
        guard let stored = defaults.dictionary(forKey: Self.preferredSizeKey),
              let width = stored["width"] as? Double,
              let height = stored["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return NSSize(width: width, height: height)
    }

    /// Observes completed queue mutations without polling or reintroducing dismissal timers.
    private func observeStoreIfNeeded() {
        guard storeObserver == nil else { return }
        storeObserver = storeProvider().objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileVisibility() }
    }

    /// Reconciles the latest state after remove/append notifications settle on the main queue.
    ///
    /// Returns:
    ///   Nothing. Quiet automatic presentations close without consuming or deleting any row.
    private func reconcileVisibility() {
        guard let presentation else { return }
        let store = storeProvider()
        if presentation.shouldHideWhenQuiet(
            items: store.items, configurationError: store.configurationError,
            isOpening: model?.openingID != nil, hasOpenFailure: model?.failure != nil
        ) {
            close()
        }
    }

    /// Applies automatic or user-selected size without fighting a live resize or revealing the panel.
    private func resizeToContent() {
        guard let panel, !panel.inLiveResize, let contentHeight,
              let screen = (panel.isVisible ? panel.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let availableSize = NSSize(
            width: max(0, screen.visibleFrame.width),
            height: max(0, screen.visibleFrame.height)
        )
        panel.contentMinSize = NSSize(width: min(layout.minimumSize.width, availableSize.width),
                                     height: min(layout.minimumSize.height, availableSize.height))
        panel.contentMaxSize = availableSize
        let frame = layout.frame(contentHeight: contentHeight, visibleFrame: screen.visibleFrame,
                                 currentFrame: panel.isVisible ? panel.frame : nil, preferredSize: preferredSize)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: panel.isVisible)
    }
}
