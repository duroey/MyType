import AppKit
import SwiftUI

/// Presents one compact project review before navigating to the native new-task composer.
@MainActor
final class AgentNewTaskWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentNewTaskWindowController()
    private let model = AgentNewTaskViewModel()
    private var window: NSWindow?
    private var preparationTask: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    private var openingID: UUID?

    /// Accepts a spoken new-task request without creating files or sending a message.
    ///
    /// Args:
    ///   text: Original voice request.
    ///   context: Foreground identity captured before intent classification.
    ///
    /// Returns:
    ///   False if another confirmed opening is still in progress.
    func show(text: String, context: AgentNewTaskContext) -> Bool {
        guard model.begin(text) else { return false }
        preparationTask?.cancel()
        let target = window ?? makeWindow()
        target.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        preparationTask = Task { [model] in await model.load(context: context) }
        return true
    }

    /// Creates a retained native window using the same theme as MyType's main interface.
    ///
    /// Returns:
    ///   The review window, without starting microphone or agent operations.
    private func makeWindow() -> NSWindow {
        let target = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.titleVisibility = .hidden
        target.titlebarAppearsTransparent = true
        target.delegate = self
        target.contentView = NSHostingView(rootView: AgentNewTaskView(
            model: model, close: { [weak self] in self?.window?.close() },
            confirm: { [weak self] in self?.confirm() },
            chooseFolder: { [weak self] in self?.chooseFolder() }
        ))
        target.center()
        window = target
        return target
    }

    /// Opens once; completion closes only MyType's review window.
    private func confirm() {
        guard openingTask == nil else { return }
        let token = UUID()
        openingID = token
        openingTask = Task { [weak self, model] in
            let accepted = await model.openConfirmedDraft()
            guard self?.openingID == token else { return }
            self?.openingTask = nil
            self?.openingID = nil
            if accepted { self?.window?.close() }
        }
    }

    /// Lets the user explicitly add a project outside the finite native history catalog.
    private func chooseFolder() {
        guard let window, !model.isOpening, !model.isPreparing else { return }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false
        chooser.canCreateDirectories = false
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = chooser.url else { return }
            self?.model.chooseProject(url)
        }
    }

    /// Invalidates late suggestion callbacks without interrupting an original agent.
    ///
    /// Args:
    ///   notification: The review window's close notification.
    func windowWillClose(_ notification: Notification) {
        preparationTask?.cancel(); preparationTask = nil
        openingTask?.cancel(); openingTask = nil
        openingID = nil
        model.cancel()
    }
}

private struct AgentNewTaskView: View {
    @ObservedObject var model: AgentNewTaskViewModel
    @AppStorage("tf_language") private var languageRaw = AppLanguage.systemDefault
    @AppStorage(SettingsTheme.storageKey) private var themeRaw = SettingsTheme.defaultValue.rawValue
    let close: () -> Void
    let confirm: () -> Void
    let chooseFolder: () -> Void
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .current }
    private var theme: SettingsTheme { SettingsTheme.resolve(themeRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: TF.spacingLG) {
            Text(copy(.title)).font(.system(size: 22, weight: .semibold))
            ScrollView {
            VStack(alignment: .leading, spacing: TF.spacingLG) {
            VStack(alignment: .leading, spacing: TF.spacingSM) {
                Text(copy(.task)).font(.system(size: 12, weight: .medium)).foregroundStyle(TF.settingsTextSecondary)
                TextEditor(text: $model.text)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(TF.spacingSM).frame(height: 110)
                    .background(TF.settingsCard, in: RoundedRectangle(cornerRadius: TF.cornerSM))
                    .accessibilityLabel(copy(.task))
            }
            .disabled(model.isPreparing || model.isOpening)
            VStack(alignment: .leading, spacing: TF.spacingSM) {
                Picker(copy(.project), selection: $model.projectID) {
                    Text(copy(.chooseProject)).tag(String?.none)
                    Text(copy(.independent)).tag(Optional(AgentNewTaskService.independentProjectID))
                    ForEach(model.projects) { project in
                        Text(projectLabel(project)).tag(Optional(project.id)).help(project.id)
                    }
                }
                HStack {
                    if model.isPreparing {
                        ProgressView().controlSize(.small)
                        Text(copy(.preparing)).font(.caption).foregroundStyle(TF.settingsTextSecondary)
                    } else {
                        Button(copy(.chooseFolder), action: chooseFolder).buttonStyle(.link)
                    }
                    Spacer()
                    Picker(copy(.application), selection: $model.application) {
                        Text(copy(.chooseApplication)).tag(AgentDesktopApplication?.none)
                        ForEach(AgentDesktopApplication.allCases, id: \.self) { application in
                            Text(application.displayName + (model.installedApplications.contains(application) ? "" : " · " + copy(.notInstalled)))
                                .tag(Optional(application))
                        }
                    }
                    .fixedSize()
                }
            }
            .disabled(model.isPreparing || model.isOpening)
            if let error = model.failure {
                Text((error as? AgentDesktopLauncherError)?.message(language: language)
                     ?? (error as? CodexNativeNoFolderService.ServiceError)?.errorDescription
                     ?? copy(.failed))
                    .font(.caption).foregroundStyle(TF.settingsAccentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.isPreparing, model.projectID == nil {
                Text(copy(.unavailable)).font(.caption).foregroundStyle(TF.settingsTextSecondary)
            }
            }
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: TF.spacingMD) {
                Text(copy(model.projectID == AgentNewTaskService.independentProjectID ? .independentHint : .projectHint))
                    .font(.caption).foregroundStyle(TF.settingsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(copy(.cancel), action: close).keyboardShortcut(.cancelAction)
                Button(copy(model.isOpening ? .opening : .sendInApp), action: confirm)
                    .buttonStyle(.borderedProminent).tint(TF.settingsAccentBlue)
                    .disabled(!model.canOpen).keyboardShortcut(.defaultAction)
            }
        }
        .padding(TF.spacingXL)
        .frame(width: 560, height: 460)
        .background(TF.settingsBg).foregroundStyle(TF.settingsText)
        .preferredColorScheme(theme.colorScheme)
        .background(NewTaskWindowAppearance(theme: theme, title: copy(.title)))
    }

    /// Adds a parent-folder hint only when multiple projects share the same name.
    ///
    /// Args:
    ///   project: One known project choice.
    ///
    /// Returns:
    ///   A recognizable label without making paths the normal product vocabulary.
    private func projectLabel(_ project: AgentNewTaskProject) -> String {
        guard model.projects.filter({ $0.name == project.name }).count > 1 else { return project.name }
        return project.name + " · " + URL(fileURLWithPath: project.id).deletingLastPathComponent().lastPathComponent
    }

    /// Renders a label from the live language preference.
    private func copy(_ label: AgentNewTaskCopy.Label) -> String { AgentNewTaskCopy.text(label, language: language) }
}

private struct NewTaskWindowAppearance: NSViewRepresentable {
    let theme: SettingsTheme
    let title: String

    /// Creates a noninteractive native appearance observer.
    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }

    /// Updates the native title and theme when the user's preferences change.
    func updateNSView(_ view: AppearanceView, context: Context) { view.theme = theme; view.title = title }

    final class AppearanceView: NSView {
        var theme = SettingsTheme.defaultValue { didSet { window?.appearance = theme.appearance } }
        var title = "" { didSet { window?.title = title } }
        /// Applies appearance when the hosting view first joins its window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = theme.appearance; window?.title = title
        }
    }
}
