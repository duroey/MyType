import AppKit
import SwiftUI

@MainActor
private final class AgentIntentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Resolves uncertainty without inventing an action or adding another hotkey.
@MainActor
final class AgentIntentPickerController: NSObject, NSWindowDelegate {
    static let shared = AgentIntentPickerController()
    private var panel: AgentIntentPanel?
    private var requestID: UUID?
    private var continuation: CheckedContinuation<AgentIntent?, Never>?

    /// Asks for an explicit action and releases a cancelled or superseded request once.
    ///
    /// Args:
    ///   text: Original request displayed verbatim for recognition.
    ///   error: Optional semantic service failure, rendered in the current language.
    ///
    /// Returns:
    ///   The chosen operation, or nil on dismissal or task cancellation.
    func choose(text: String, error: AgentIntentClassifierError? = nil) async -> AgentIntent? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                guard !Task.isCancelled else { pending.resume(returning: nil); return }
                if let previous = requestID { finish(id: previous, intent: nil) }
                requestID = id
                continuation = pending
                let window = AgentIntentPanel(
                    contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                    backing: .buffered, defer: false
                )
                window.delegate = self
                window.isReleasedWhenClosed = false
                window.isFloatingPanel = true
                window.level = .floating
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.hidesOnDeactivate = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = AgentIntentPickerView(text: text, error: error) { [weak self] intent in
                    self?.finish(id: id, intent: intent)
                }
                let hosting = NSHostingView(rootView: view)
                window.contentView = hosting
                panel = window
                let size = hosting.fittingSize
                if let screen = FloatingBarPanel.screenUnderMouse() {
                    let frame = screen.visibleFrame
                    window.setFrame(NSRect(
                        x: frame.midX - size.width / 2,
                        y: frame.midY - size.height / 2,
                        width: size.width, height: size.height
                    ), display: false)
                } else {
                    window.setContentSize(size)
                    window.center()
                }
                window.makeKeyAndOrderFront(nil)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id: id, intent: nil) }
        }
    }

    /// Completes only the owning request, so a late cancellation cannot close a newer choice.
    ///
    /// Args:
    ///   id: Request identity captured when the panel was presented.
    ///   intent: Explicit choice, or nil when cancelled.
    private func finish(id: UUID, intent: AgentIntent?) {
        guard requestID == id else { return }
        let pending = continuation
        continuation = nil
        requestID = nil
        panel?.orderOut(nil)
        panel = nil
        pending?.resume(returning: intent)
    }

    /// Treats a native window dismissal as cancellation of its own pending request.
    ///
    /// Args:
    ///   notification: Close event from the active panel.
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === panel,
              let id = requestID else { return }
        finish(id: id, intent: nil)
    }
}

private struct AgentIntentPickerView: View {
    @AppStorage("tf_language") private var languageRaw = AppLanguage.systemDefault
    @AppStorage(RecordingTheme.storageKey) private var theme = RecordingTheme.defaultValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .current }
    private var textColor: Color { theme == .light ? TF.floatingTextLight : TF.floatingText }
    let text: String
    let error: AgentIntentClassifierError?
    let choose: (AgentIntent?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(language == .zh ? "要做哪件事？" : "What would you like to do?", systemImage: "arrow.triangle.branch")
                .font(.headline)
            Text(text).font(.body).lineLimit(4).textSelection(.enabled)
            Text(error?.message(language: language) ?? (language == .zh
                ? "还没确定你的意思，请选一下。" : "Your intent isn't clear yet. Choose an action."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(language == .zh ? "找回会话" : "Find a conversation") { choose(.wake) }
                Button(language == .zh ? "交接工作" : "Hand off work") { choose(.handoff) }
                Spacer()
                Button(language == .zh ? "取消" : "Cancel") { choose(nil) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: AgentActivityPickerLayout.preferredWidth)
        .foregroundStyle(textColor)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AgentActivityPickerLayout.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AgentActivityPickerLayout.cornerRadius)
                .strokeBorder(textColor.opacity(0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, theme == .light ? .light : .dark)
    }
}
