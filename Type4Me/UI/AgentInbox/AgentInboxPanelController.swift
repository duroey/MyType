import AppKit
import Combine
import SwiftUI

enum AgentInboxPresentation: Equatable {
    case userRequested
    case taskCompleted

    var requestsKeyboardFocus: Bool { self == .userRequested }

    /// Decides whether a notification-opened panel no longer needs user attention.
    ///
    /// Args:
    ///   items: Latest complete queue snapshot, after the store finishes its update.
    ///   storageError: Whether a visible persistence warning still needs attention.
    ///
    /// Returns:
    ///   True only for an automatic panel with no results, requests, or problems to review.
    func shouldHideWhenQuiet(items: [AgentInboxItem], storageError: Bool) -> Bool {
        guard self == .taskCompleted, !storageError else { return false }
        return !items.contains { item in
            if !item.pendingRequests.isEmpty { return true }
            switch item.status {
            case .completed, .failed, .interrupted: return true
            case .unknown, .idle: return item.isUnread
            case .running, .waiting: return false
            }
        }
    }
}

struct AgentInboxPanelLayout {
    var preferredWidth: CGFloat = 420
    var preferredHeight: CGFloat = 560
    var screenInset: CGFloat = TF.spacingLG
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
    private var presentation: AgentInboxPresentation?
    private var presentationRevision = 0
    private var visibilityObserver: AnyCancellable?

    /// Creates the persistent queue panel without opening a window or starting monitoring.
    ///
    /// Args:
    ///   layout: Bounded panel dimensions and screen margins.
    ///   storeProvider: Supplies the shared inbox only when presentation needs it.
    ///   present: Optional window-free presentation observer for policy tests.
    ///   dismiss: Optional window-free counterpart for dismissal tests.
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

    /// Opens the inbox in response to an explicit menu action.
    ///
    /// Returns:
    ///   Nothing. Only this user-requested route may request keyboard focus.
    func show() {
        present(.userRequested)
    }

    /// Reveals the shared queue for a newly verified task completion.
    ///
    /// Args:
    ///   item: Completed session snapshot emitted by the store after deduplication.
    ///
    /// Returns:
    ///   Nothing. The current app and keyboard focus remain unchanged.
    func showCompletion(_ item: AgentInboxItem) {
        guard item.status == .completed else { return }
        present(.taskCompleted)
    }

    /// Hides the panel while keeping all session state in the inbox store.
    ///
    /// Returns:
    ///   Nothing. Closing never interrupts or approves a native conversation.
    func close() {
        presentation = nil
        model?.resetPresentation()
        if let dismissOverride { dismissOverride() } else { panel?.orderOut(nil) }
    }

    /// Releases presentation resources during app shutdown.
    ///
    /// Returns:
    ///   Nothing. Monitoring is stopped separately by the owning service.
    func stop() {
        visibilityObserver = nil
        close()
        panel?.contentView = nil
        panel = nil
        model = nil
    }

    /// Presents the same queue surface for manual opening and task completion.
    ///
    /// Args:
    ///   reason: Determines whether keyboard focus was explicitly requested.
    ///
    /// Returns:
    ///   Nothing. Completion never calls an app-activation or key-window API.
    private func present(_ reason: AgentInboxPresentation) {
        presentationRevision &+= 1
        // New completions must not turn a manually opened queue into an automatic one.
        if presentation != .userRequested { presentation = reason }
        if let presentOverride {
            presentOverride(reason)
            return
        }
        if panel == nil { createPanel() }
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if !panel.isVisible {
            let visible = screen.visibleFrame
            let width = min(layout.preferredWidth, max(0, visible.width - layout.screenInset * 2))
            let height = min(layout.preferredHeight, max(0, visible.height - layout.screenInset * 2))
            panel.setFrame(NSRect(
                x: visible.maxX - width - layout.screenInset,
                y: visible.maxY - height - layout.screenInset,
                width: width, height: height
            ), display: false)
        }
        if reason.requestsKeyboardFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Lazily hosts the settings-styled queue in a nonactivating floating panel.
    ///
    /// Returns:
    ///   Nothing. Manual browsing stays open; automatic presentation can become quiet.
    private func createPanel() {
        let store = storeProvider()
        let model = AgentInboxViewModel(
            markRead: { [weak store] selected in
                // Opening may overlap a fresh update; consume only the update the user selected.
                guard store?.items.first(where: { $0.id == selected.id }) == selected else { return }
                store?.markRead(selected.id)
                // Native viewing evidence, not URL acceptance, removes completed messages.
            },
            onOpened: { [weak self] in self?.close() },
            presentationRevision: { [weak self] in self?.presentationRevision ?? 0 }
        )
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
        panel.contentView = NSHostingView(rootView: AgentInboxView(
            store: store, model: model, onClose: { [weak self] in self?.close() }
        ))
        self.model = model
        self.panel = panel
        visibilityObserver = Publishers.Merge(store.objectWillChange, model.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hideIfQuiet() }
    }

    /// Reconciles visibility after published mutations finish, without polling.
    ///
    /// Returns:
    ///   Nothing. In-flight navigation and visible launch errors keep the queue available.
    private func hideIfQuiet() {
        guard let presentation, model?.openingID == nil, model?.failure == nil else { return }
        let store = storeProvider()
        // Use current state, not transient remove/append snapshots from a store update.
        if presentation.shouldHideWhenQuiet(items: store.items, storageError: store.storageError) {
            close()
        }
    }
}
