import AppKit
import Combine
import SwiftUI

enum AgentInboxPresentation: Equatable {
    case userRequested
    case taskCompleted
    case needsResponse

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
        guard self != .userRequested, !storageError else { return false }
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
    static let shared: AgentInboxPanelController = {
        do { return AgentInboxPanelController(configuration: try .bundled()) }
        catch {
            NSLog("[AgentInbox] Invalid panel configuration; using bounded presentation defaults.")
            return AgentInboxPanelController()
        }
    }()

    private let layout: AgentInboxPanelLayout
    private let configuration: AgentNotificationConfiguration
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let storeProvider: @MainActor () -> AgentInboxStore
    private let presentOverride: ((AgentInboxPresentation) -> Void)?
    private let dismissOverride: (() -> Void)?
    private var panel: AgentInboxPanel?
    private var model: AgentInboxViewModel?
    private var presentation: AgentInboxPresentation?
    private var presentationRevision = 0
    private var visibilityObserver: AnyCancellable?
    private var navigationObserver: AnyCancellable?
    private var pointerInside = false
    private var navigationInProgress = false
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var autoHideTask: Task<Void, Never>?
    private var autoHideRevision = 0
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var applicationObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []

    /// Creates the persistent queue panel without opening a window or starting monitoring.
    ///
    /// Args:
    ///   layout: Bounded panel dimensions and screen margins.
    ///   configuration: Notification display duration; tests can supply isolated bounds.
    ///   sleep: Replaceable delay for window-free presentation checks.
    ///   storeProvider: Supplies the shared inbox only when presentation needs it.
    ///   present: Optional window-free presentation observer for policy tests.
    ///   dismiss: Optional window-free counterpart for dismissal tests.
    init(
        layout: AgentInboxPanelLayout = AgentInboxPanelLayout(),
        configuration: AgentNotificationConfiguration = AgentNotificationConfiguration(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        storeProvider: @escaping @MainActor () -> AgentInboxStore = { AgentInboxStore.shared },
        present: ((AgentInboxPresentation) -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) {
        self.layout = layout
        self.configuration = configuration
        self.sleep = sleep
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

    /// Reveals a newly observed native question or approval without stealing keyboard focus.
    ///
    /// Args:
    ///   item: Current queue snapshot containing at least one unresolved native request.
    func showRequest(_ item: AgentInboxItem) {
        guard !item.pendingRequests.isEmpty else { return }
        present(.needsResponse)
    }

    /// Hides the panel while keeping all session state in the inbox store.
    ///
    /// Returns:
    ///   Nothing. Closing never interrupts or approves a native conversation.
    func close() {
        presentation = nil
        cancelAutoHide()
        removeInteractionObservers()
        pointerInside = false
        navigationInProgress = false
        model?.resetPresentation()
        if let dismissOverride { dismissOverride() } else { panel?.orderOut(nil) }
    }

    /// Releases presentation resources during app shutdown.
    ///
    /// Returns:
    ///   Nothing. Monitoring is stopped separately by the owning service.
    func stop() {
        visibilityObserver = nil
        navigationObserver = nil
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
            scheduleAutoHide()
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
        pointerInside = panel.frame.contains(NSEvent.mouseLocation)
        installInteractionObservers()
        scheduleAutoHide()
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
            store: store, model: model, onClose: { [weak self] in self?.close() },
            onHoverChanged: { [weak self] inside in self?.setPointerInside(inside) }
        ))
        self.model = model
        self.panel = panel
        visibilityObserver = Publishers.Merge(store.objectWillChange, model.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hideIfQuiet() }
        navigationObserver = model.$openingID
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.setNavigationInProgress(active) }
    }

    /// Dismisses only the presentation after a click outside the queue.
    ///
    /// Returns:
    ///   Nothing. All unread messages and outstanding native requests remain stored.
    func handleOutsideInteraction() {
        guard presentation != nil, trackingMenus.isEmpty else { return }
        close()
    }

    /// Hides on app switching, except while this queue is opening a native conversation.
    ///
    /// Returns:
    ///   Nothing. Navigation owns its success callback and selected-message receipt.
    func handleApplicationChange() {
        guard presentation != nil, !isNavigating else { return }
        close()
    }

    /// Pauses a notification while its full surface is being read or interacted with.
    ///
    /// Args:
    ///   inside: Whether the pointer is currently over the visible queue.
    func setPointerInside(_ inside: Bool) {
        guard presentation != nil, pointerInside != inside else { return }
        pointerInside = inside
        scheduleAutoHide()
    }

    /// Gives a navigation result a fresh reading interval after the opener returns.
    ///
    /// Args:
    ///   active: Whether an exact-session opening is still in progress.
    func setNavigationInProgress(_ active: Bool) {
        guard navigationInProgress != active else { return }
        navigationInProgress = active
        scheduleAutoHide()
    }

    private var isNavigating: Bool { navigationInProgress || model?.openingID != nil }

    /// Arms a bounded notification timeout without expiring manually opened queues.
    ///
    /// Returns:
    ///   Nothing. Old delays cannot close a newer presentation or an active interaction.
    private func scheduleAutoHide() {
        cancelAutoHide()
        guard presentation != nil, presentation != .userRequested, !pointerInside, !isNavigating,
              trackingMenus.isEmpty else { return }
        let revision = autoHideRevision
        let visibleRevision = presentationRevision
        let delay = configuration.inboxAutoHideSeconds
        let sleep = self.sleep
        autoHideTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) }
            catch { return }
            guard !Task.isCancelled, let self, self.autoHideRevision == revision,
                  self.presentationRevision == visibleRevision,
                  self.presentation != nil, self.presentation != .userRequested, !self.isNavigating,
                  !self.pointerInside, self.trackingMenus.isEmpty else { return }
            // An inactive panel can appear underneath an already stationary pointer.
            if let panel = self.panel, panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) {
                self.setPointerInside(true)
                return
            }
            self.close()
        }
    }

    /// Invalidates even a delay implementation that delivers after cancellation.
    private func cancelAutoHide() {
        autoHideRevision &+= 1
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// Observes clicks and app changes only while the queue is visible.
    ///
    /// Returns:
    ///   Nothing. Click events continue to their original targets unchanged.
    private func installInteractionObservers() {
        let alreadyTracking = trackingMenus
        removeInteractionObservers()
        trackingMenus = alreadyTracking
        let revision = presentationRevision
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.presentationRevision == revision,
                  let panel = self.panel, event.window !== panel else { return event }
            self.handleOutsideInteraction()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, self.presentationRevision == revision else { return }
            self.handleOutsideInteraction()
        }
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.presentationRevision == revision,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.handleApplicationChange()
            }
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.presentationRevision == revision,
                          let menu = notification.object as? NSMenu else { return }
                    if notification.name == NSMenu.didBeginTrackingNotification {
                        self.trackingMenus.insert(ObjectIdentifier(menu))
                    } else {
                        self.trackingMenus.remove(ObjectIdentifier(menu))
                    }
                    self.scheduleAutoHide()
                }
            })
        }
    }

    /// Releases all native input observers when this presentation is hidden or stopped.
    private func removeInteractionObservers() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let applicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver)
        }
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        localClickMonitor = nil
        globalClickMonitor = nil
        applicationObserver = nil
        menuObservers.removeAll()
        trackingMenus.removeAll()
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
