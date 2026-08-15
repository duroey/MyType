import SwiftUI
import AppKit

// MARK: - Shared Style

private enum SettingsFieldStyle {
    static let textColor = NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    static let placeholderColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)
    static let cursorColor = NSColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)

    /// Configure a bare NSTextField: transparent, no border, just text editing.
    static func applyCommon(to field: NSTextField, placeholder: String) {
        // Prevent cursor from changing outside visible bounds
        field.wantsLayer = true
        field.layer?.masksToBounds = true
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = textColor
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byTruncatingTail

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: style,
            ]
        )

        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

// MARK: - NSTextField subclass (cursor color + no intrinsic width)

private class SettingsNSTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
    override func resetCursorRects() {
        // Only show I-beam cursor when the field is editable and visible
        if isEditable && !isHidden && alphaValue > 0 {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable && !isHidden && alphaValue > 0 else { return nil }
        return super.hitTest(point)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SettingsFieldStyle.cursorColor
        }
        return result
    }
}

private class SettingsNSSecureTextField: NSSecureTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
    override func resetCursorRects() {
        if isEditable && !isHidden && alphaValue > 0 {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable && !isHidden && alphaValue > 0 else { return nil }
        return super.hitTest(point)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SettingsFieldStyle.cursorColor
        }
        return result
    }
}

// MARK: - SwiftUI Wrappers (bare text field, no visual styling)

/// Bare NSTextField wrapper. All visual styling (background, corner radius, padding)
/// is applied via SwiftUI modifiers in settingsField().
struct FixedWidthTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var commitOnReturnOrOutsideClick = false
    var onEditingEnded: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = SettingsNSTextField()
        SettingsFieldStyle.applyCommon(to: field, placeholder: placeholder)
        field.delegate = context.coordinator
        context.coordinator.attach(field: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            commitOnReturnOrOutsideClick: commitOnReturnOrOutsideClick,
            onEditingEnded: onEditingEnded
        )
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var commitOnReturnOrOutsideClick: Bool
        var onEditingEnded: ((String) -> Void)?
        private weak var field: NSTextField?
        private var mouseDownMonitor: Any?

        init(
            text: Binding<String>,
            commitOnReturnOrOutsideClick: Bool,
            onEditingEnded: ((String) -> Void)?
        ) {
            self.text = text
            self.commitOnReturnOrOutsideClick = commitOnReturnOrOutsideClick
            self.onEditingEnded = onEditingEnded
        }

        deinit {
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
        }

        /// Attaches the coordinator to its AppKit field and installs optional outside-click commit handling.
        ///
        /// Args:
        ///   field: Backing text field created by SwiftUI.
        func attach(field: NSTextField) {
            self.field = field
            guard commitOnReturnOrOutsideClick, mouseDownMonitor == nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.commitIfClickIsOutsideField(event)
                return event
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            onEditingEnded?(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commitOnReturnOrOutsideClick,
                  commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            else {
                return false
            }
            commitAndEndEditing(field: control as? NSTextField, value: textView.string)
            return true
        }

        private func commitIfClickIsOutsideField(_ event: NSEvent) {
            guard let field,
                  let window = field.window,
                  event.window === window,
                  let editor = field.currentEditor(),
                  window.firstResponder === editor
            else {
                return
            }
            let pointInField = field.convert(event.locationInWindow, from: nil)
            guard !field.bounds.contains(pointInField) else { return }
            commitAndEndEditing(field: field, value: editor.string)
        }

        private func commitAndEndEditing(field: NSTextField?, value: String) {
            field?.stringValue = value
            text.wrappedValue = value
            onEditingEnded?(value)
            field?.window?.makeFirstResponder(nil)
        }
    }
}

/// Bare NSSecureTextField wrapper.
struct FixedWidthSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = SettingsNSSecureTextField()
        SettingsFieldStyle.applyCommon(to: field, placeholder: placeholder)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
