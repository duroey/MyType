import AppKit
import SwiftUI

@MainActor
private final class AgentActivityPickerPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Handles picker shortcuts only when the event belongs to this panel.
    ///
    /// Args:
    ///   event: AppKit event addressed to the picker window.
    ///
    /// Returns:
    ///   Nothing. Unhandled events continue through the normal responder chain.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class AgentActivityPickerPanelController {
    static let shared = AgentActivityPickerPanelController()

    private struct Request {
        let id: UUID
        let continuation: CheckedContinuation<AgentActivityCandidate?, Never>
        let onRename: @Sendable (UUID, String) async throws -> Void
        let onLink: @Sendable (String, UUID) async throws -> Void
    }

    private let state = AgentActivityPickerState()
    private var panel: AgentActivityPickerPanel?
    private var request: Request?
    private var updateTask: Task<Void, Never>?
    private let presentOverride: ((AgentActivityPickerState) -> Void)?
    private let dismissOverride: (() -> Void)?

    /// Creates a lazy picker controller with optional window-free test presentation.
    ///
    /// Args:
    ///   present: Optional presenter that receives callback state without creating a window.
    ///   dismiss: Optional counterpart that replaces window dismissal.
    ///
    /// Returns:
    ///   A controller that creates an AppKit panel only when its default presenter is used.
    init(
        present: ((AgentActivityPickerState) -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) {
        presentOverride = present
        dismissOverride = dismiss
    }

    /// Presents a cancellable activity choice and resolves exactly once.
    ///
    /// Args:
    ///   query: Spoken activity name, or empty text for the full activity browser.
    ///   candidates: Frozen candidates, including those that cannot yet be opened.
    ///   onRename: Persists a user-supplied activity name.
    ///   onLink: Associates a stable provider/session identity with another activity.
    ///
    /// Returns:
    ///   The current candidate after local name or association changes, or nil
    ///   when cancelled, replaced by a newer request, or its task is cancelled.
    func choose(
        query: String,
        candidates: [AgentActivityCandidate],
        onRename: @escaping @Sendable (UUID, String) async throws -> Void,
        onLink: @escaping @Sendable (String, UUID) async throws -> Void
    ) async -> AgentActivityCandidate? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                hide()
                request = Request(
                    id: requestID, continuation: continuation, onRename: onRename, onLink: onLink
                )
                state.query = query
                state.candidates = candidates
                state.editingActivityID = nil
                state.nameDraft = ""
                state.error = nil
                state.isUpdating = false
                state.onSelect = { [weak self] sessionID in
                    self?.select(sessionID: sessionID, requestID: requestID)
                }
                state.onCancel = { [weak self] in self?.finish(requestID: requestID, selection: nil) }
                state.onRename = { [weak self] activityID, name in
                    self?.rename(activityID: activityID, name: name, requestID: requestID)
                }
                state.onLink = { [weak self] sessionID, activityID in
                    self?.link(sessionID: sessionID, activityID: activityID, requestID: requestID)
                }
                if let presentOverride { presentOverride(state) } else { showPanel() }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(requestID: requestID, selection: nil) }
        }
    }

    /// Cancels the currently presented request without creating a panel.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Resumes the current chooser once with no selection.
    func hide() {
        guard let request else { return }
        finish(requestID: request.id, selection: nil)
    }

    /// Creates the persistent hosting window lazily and places it above the floating bar.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Makes only the picker window key for text editing and shortcuts.
    private func showPanel() {
        if panel == nil {
            let panel = AgentActivityPickerPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AgentActivityPickerView(state: state))
            panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
            self.panel = panel
        }
        guard let panel, let screen = FloatingBarPanel.screenUnderMouse() else {
            hide()
            return
        }
        let visible = screen.visibleFrame
        let inset = AgentActivityPickerLayout.screenInset
        let width = min(AgentActivityPickerLayout.preferredWidth, visible.width - inset * 2)
        let height = min(AgentActivityPickerLayout.preferredHeight, visible.height - inset * 2)
        let preferredY = visible.minY + TF.barBottomOffset + TF.barHeight + AgentActivityPickerLayout.floatingBarGap
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: min(preferredY, visible.maxY - height - inset),
            width: width, height: height
        )
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Resolves a concrete session identity against the latest local candidate state.
    ///
    /// Args:
    ///   sessionID: Stable provider/session identity selected by a row or shortcut.
    ///   requestID: Request that owns this selection callback.
    ///
    /// Returns:
    ///   Nothing. Returns an updated candidate only when it can open its original conversation.
    private func select(sessionID: String, requestID: UUID) {
        guard request?.id == requestID, !state.isUpdating,
              let candidate = state.candidates.first(where: { $0.session.id == sessionID }),
              candidate.canOpen else { return }
        finish(requestID: requestID, selection: candidate)
    }

    /// Completes only the owning request and clears its callbacks before resuming it.
    ///
    /// Args:
    ///   requestID: Request identity to complete.
    ///   selection: Chosen candidate, or nil for cancellation.
    ///
    /// Returns:
    ///   Nothing. A stale cancellation cannot close a newer picker or resume twice.
    private func finish(requestID: UUID, selection: AgentActivityCandidate?) {
        guard let request, request.id == requestID else { return }
        self.request = nil
        updateTask?.cancel()
        updateTask = nil
        state.onSelect = nil
        state.onCancel = nil
        state.onRename = nil
        state.onLink = nil
        if let dismissOverride { dismissOverride() } else { panel?.orderOut(nil) }
        request.continuation.resume(returning: selection)
    }

    /// Saves an activity name and updates every candidate within the same activity.
    ///
    /// Args:
    ///   activityID: Stable activity identity whose name is edited.
    ///   name: User-entered draft.
    ///   requestID: Request that owns this editing action.
    ///
    /// Returns:
    ///   Nothing. Save failures become language-independent inline error states.
    private func rename(activityID: UUID, name: String, requestID: UUID) {
        guard let request, request.id == requestID, !state.isUpdating,
              state.candidates.contains(where: { $0.activityID == activityID }) else { return }
        guard let name = AgentActivityPickerCopy.normalizedName(name) else {
            state.error = .missingName
            return
        }
        state.isUpdating = true
        state.error = nil
        updateTask = Task { @MainActor [weak self] in
            do {
                try await request.onRename(activityID, name)
                guard let self, self.request?.id == requestID, !Task.isCancelled else { return }
                self.state.candidates = AgentActivityPickerCopy.renamedCandidates(
                    activityID: activityID, title: name, candidates: self.state.candidates
                )
                self.state.editingActivityID = nil
                self.state.isUpdating = false
                self.updateTask = nil
            } catch {
                guard let self, self.request?.id == requestID, !Task.isCancelled else { return }
                self.state.isUpdating = false
                self.state.error = AgentActivityPickerCopy.errorLabel(error, fallback: .renameFailed)
                self.updateTask = nil
            }
        }
    }

    /// Moves a concrete session candidate to another activity after persistence succeeds.
    ///
    /// Args:
    ///   sessionID: Stable provider/session identity to associate.
    ///   activityID: Destination activity identity from the current candidate groups.
    ///   requestID: Request that owns this association action.
    ///
    /// Returns:
    ///   Nothing. Preserves candidate order and records a localized inline failure state.
    private func link(sessionID: String, activityID: UUID, requestID: UUID) {
        guard let request, request.id == requestID, !state.isUpdating,
              state.candidates.contains(where: { $0.session.id == sessionID && $0.activityID != activityID }),
              let title = state.candidates.first(where: { $0.activityID == activityID })?.activityTitle
        else { return }
        state.isUpdating = true
        state.error = nil
        updateTask = Task { @MainActor [weak self] in
            do {
                try await request.onLink(sessionID, activityID)
                guard let self, self.request?.id == requestID, !Task.isCancelled else { return }
                self.state.candidates = AgentActivityPickerCopy.linkedCandidates(
                    sessionKey: sessionID, activityID: activityID, title: title,
                    candidates: self.state.candidates
                )
                self.state.editingActivityID = nil
                self.state.isUpdating = false
                self.updateTask = nil
            } catch {
                guard let self, self.request?.id == requestID, !Task.isCancelled else { return }
                self.state.isUpdating = false
                self.state.error = AgentActivityPickerCopy.errorLabel(error, fallback: .linkFailed)
                self.updateTask = nil
            }
        }
    }

    /// Applies digit, Return, and Escape shortcuts only to the current picker request.
    ///
    /// Args:
    ///   event: Key-down event sent to the picker panel itself.
    ///
    /// Returns:
    ///   Whether the picker handled the event; name editing retains normal typing.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let request,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        if event.keyCode == AgentActivityPickerLayout.escapeKeyCode {
            finish(requestID: request.id, selection: nil)
            return true
        }
        guard state.editingActivityID == nil, !state.isUpdating else { return false }
        if AgentActivityPickerLayout.returnKeyCodes.contains(event.keyCode),
           let candidate = state.candidates.first(where: \.canOpen) {
            select(sessionID: candidate.session.id, requestID: request.id)
            return true
        }
        guard let characters = event.charactersIgnoringModifiers,
              let number = Int(characters), AgentActivityPickerLayout.digitShortcuts.contains(number),
              state.candidates.indices.contains(number - 1) else { return false }
        select(sessionID: state.candidates[number - 1].session.id, requestID: request.id)
        return true
    }
}
