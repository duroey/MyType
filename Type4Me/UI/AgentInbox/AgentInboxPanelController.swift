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
    ///   storageError: Whether the queue still displays a persistence warning.
    ///   isOpening: Whether native navigation is in progress.
    ///   hasOpenFailure: Whether the user needs to see a navigation error.
    ///
    /// Returns:
    ///   True for a quiet automatic panel; manually opened panels always stay visible.
    func shouldHideWhenQuiet(
        items: [AgentInboxItem], storageError: Bool = false,
        isOpening: Bool = false, hasOpenFailure: Bool = false
    ) -> Bool {
        self != .userRequested && !storageError && !isOpening && !hasOpenFailure
            && !items.contains(where: \.needsAttention)
    }
}

/// Shared sizing configuration for the native panel and its measured SwiftUI content.
struct AgentInboxPanelLayout {
    var preferredWidth: CGFloat = 420
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
    ///
    /// Returns:
    ///   A display-bounded frame anchored to the current or default upper-right corner.
    func frame(contentHeight: CGFloat, visibleFrame: NSRect, currentFrame: NSRect? = nil) -> NSRect {
        let width = min(preferredWidth, max(0, visibleFrame.width - screenInset * 2))
        let height = min(max(0, contentHeight), max(0, visibleFrame.height - screenInset * 2))
        let right = min(max(currentFrame?.maxX ?? visibleFrame.maxX - screenInset,
                            visibleFrame.minX + screenInset + width), visibleFrame.maxX - screenInset)
        let top = min(max(currentFrame?.maxY ?? visibleFrame.maxY - screenInset,
                          visibleFrame.minY + screenInset + height), visibleFrame.maxY - screenInset)
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

@MainActor
final class AgentInboxPanelController {
    static let shared = AgentInboxPanelController()

    private let layout: AgentInboxPanelLayout
    private let storeProvider: @MainActor () -> AgentInboxStore
    private let presentOverride: ((AgentInboxPresentation) -> Void)?
    private let dismissOverride: (() -> Void)?
    private var panel: AgentInboxPanel?
    private var model: AgentInboxViewModel?
    private var contentHeight: CGFloat?
    private var storeObserver: AnyCancellable?
    private var navigationObserver: AnyCancellable?
    private(set) var presentation: AgentInboxPresentation?

    /// Creates a persistent queue without a window, timers, or global interaction observers.
    ///
    /// Args:
    ///   layout: Shared content sizing and screen margins.
    ///   storeProvider: Supplies the shared inbox only when native presentation needs it.
    ///   present: Optional window-free presentation observer for isolated checks.
    ///   dismiss: Optional window-free counterpart for explicit dismissal.
    init(
        layout: AgentInboxPanelLayout = AgentInboxPanelLayout(),
        storeProvider: @escaping @MainActor () -> AgentInboxStore = { AgentInboxStore.shared },
        present: ((AgentInboxPresentation) -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) {
        self.layout = layout
        self.storeProvider = storeProvider
        presentOverride = present
        dismissOverride = dismiss
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
        if let dismissOverride { dismissOverride() } else { panel?.orderOut(nil) }
    }

    /// Releases the panel during application shutdown without consuming messages.
    func stop() {
        storeObserver = nil
        navigationObserver = nil
        close()
        panel?.contentView = nil
        panel = nil
        model = nil
        contentHeight = nil
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
            // Opening can overlap a fresh update; acknowledge only the snapshot that was selected.
            guard store?.items.first(where: { $0.id == selected.id }) == selected else { return }
            store?.markRead(selected.id)
            // Native viewing evidence, not URL acceptance, removes completed messages.
        })
        let panel = AgentInboxPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        self.model = model
        self.panel = panel
        navigationObserver = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileVisibility() }
        contentHeight = layout.contentHeight(itemIDs: store.items.map(\.id), measurements: [:])
        panel.contentView = NSHostingView(rootView: AgentInboxView(
            store: store, model: model, layout: layout,
            onClose: { [weak self] in self?.close() },
            onContentHeightChange: { [weak self] height in
                guard let self, height.isFinite, height > 0, self.contentHeight != height else { return }
                self.contentHeight = height
                self.resizeToContent()
            }
        ))
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
            items: store.items, storageError: store.storageError,
            isOpening: model?.openingID != nil, hasOpenFailure: model?.failure != nil
        ) {
            close()
        }
    }

    /// Applies measured height without activating, reordering, or revealing a hidden panel.
    private func resizeToContent() {
        guard let panel, let contentHeight,
              let screen = (panel.isVisible ? panel.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = layout.frame(contentHeight: contentHeight, visibleFrame: screen.visibleFrame,
                                 currentFrame: panel.isVisible ? panel.frame : nil)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: panel.isVisible)
    }
}
