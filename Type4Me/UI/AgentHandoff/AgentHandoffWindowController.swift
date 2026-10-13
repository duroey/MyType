import AppKit
import SwiftUI

/// Owns the shared review window used by menu and Agent-hotkey handoff requests.
@MainActor
final class AgentHandoffWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentHandoffWindowController()

    private let model = AgentHandoffViewModel()
    private var handoffWindow: NSWindow?

    /// Opens the existing handoff workflow without submitting history or choosing conversations.
    ///
    /// Args:
    ///   voiceInstruction: Optional original voice request used to start a new, unselected draft.
    ///
    /// Returns:
    ///   Whether the request was accepted. A voice request cannot replace an active delivery.
    @discardableResult
    func show(voiceInstruction: String? = nil) -> Bool {
        if let voiceInstruction, !model.beginVoiceDraft(voiceInstruction) { return false }
        let window = handoffWindow ?? makeWindow()
        window.title = AgentHandoffCopy.text(.title, language: AppLanguage.current)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await model.refreshSessions() }
        return true
    }

    /// Creates one retained native window while leaving the draft and delivery in the existing model.
    ///
    /// Returns:
    ///   The shared window, sized to match the previous handoff scene.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AgentHandoffView(model: model))
        window.contentMinSize = NSSize(width: 940, height: 680)
        window.setFrameAutosaveName("AgentHandoffWindow")
        window.center()
        handoffWindow = window
        return window
    }

    /// Discards an unsubmitted preview when the retained window is closed.
    ///
    /// Args:
    ///   notification: The native close event for this controller's handoff window.
    func windowWillClose(_ notification: Notification) {
        model.clearUnsentPreview()
    }
}
