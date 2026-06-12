import AppKit
import SwiftUI

// MARK: - NSPanel Subclass

/// Non-activating floating panel that never steals focus from the target app.
/// Forces dark appearance for the sci-fi themed floating bar.
final class FloatingBarPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Positions the panel at the bottom center of the active screen.
    func positionAtBottomCenter() {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.origin.y + TF.barBottomOffset - 16  // compensate for shadow inset
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Positions the panel near the right side of the camera/notch area.
    func positionAtTopCenter() {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let x = visible.midX + TF.focusIndicatorNotchSideOffset - frame.width / 2
        let y = visible.maxY - frame.height - TF.focusIndicatorTopOffset
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Returns the screen that should host transient status UI.
    ///
    /// Returns:
    ///   The screen containing the mouse cursor, or the main screen as fallback.
    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

// MARK: - Notch Indicator

/// Two-dot indicator pinned to both sides of the camera notch.
private final class NotchIndicatorController {
    private let dotSize: CGFloat = 8
    private let dotInset: CGFloat = 12
    private let leftPanel: NSPanel
    private let rightPanel: NSPanel
    private let leftLayer: CALayer
    private let rightLayer: CALayer
    private var isVisible = false
    private var generation: UInt = 0

    init() {
        (leftPanel, leftLayer) = Self.makeDotPanel(size: dotSize)
        (rightPanel, rightLayer) = Self.makeDotPanel(size: dotSize)
    }

    /// Shows the two notch-side dots.
    func show() {
        generation &+= 1
        updateFrames()
        setColor(NSColor(srgbRed: 0.0, green: 0.4, blue: 1.0, alpha: 1.0))
        guard !isVisible else { return }
        isVisible = true
        leftPanel.alphaValue = 0
        rightPanel.alphaValue = 0
        leftPanel.orderFrontRegardless()
        rightPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            leftPanel.animator().alphaValue = 1
            rightPanel.animator().alphaValue = 1
        }
    }

    /// Hides the two notch-side dots.
    ///
    /// Args:
    ///   animated: Whether to fade the dots out before ordering the panels out.
    func hide(animated: Bool = true) {
        generation &+= 1
        let expectedGeneration = generation
        isVisible = false
        guard leftPanel.isVisible || rightPanel.isVisible else { return }
        guard animated else {
            leftPanel.alphaValue = 0
            rightPanel.alphaValue = 0
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leftPanel.animator().alphaValue = 0
            rightPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self, leftPanel, rightPanel] in
            guard let self, self.generation == expectedGeneration, !self.isVisible else { return }
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
        })
    }

    /// Recomputes dot frames from the active screen's notch geometry.
    private func updateFrames() {
        guard let screen = Self.activeScreen() else { return }
        let notch = Self.notchGeometry(on: screen)
        let y = notch.origin.y + (notch.height - dotSize) / 2
        let leftX = notch.origin.x - dotInset - dotSize / 2
        let rightX = notch.maxX + dotInset - dotSize / 2
        leftPanel.setFrame(NSRect(x: leftX, y: y, width: dotSize, height: dotSize), display: false)
        rightPanel.setFrame(NSRect(x: rightX, y: y, width: dotSize, height: dotSize), display: false)
    }

    /// Updates both dot colors.
    ///
    /// Args:
    ///   color: The AppKit color to apply to both dot layers.
    private func setColor(_ color: NSColor) {
        leftLayer.backgroundColor = color.cgColor
        rightLayer.backgroundColor = color.cgColor
    }

    /// Creates one transparent dot panel.
    ///
    /// Args:
    ///   size: Dot diameter in points.
    ///
    /// Returns:
    ///   A configured non-activating panel and its backing layer.
    private static func makeDotPanel(size: CGFloat) -> (NSPanel, CALayer) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary, .ignoresCycle]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        content.wantsLayer = true
        let layer = content.layer ?? CALayer()
        content.layer = layer
        layer.cornerRadius = size / 2
        layer.masksToBounds = true
        panel.contentView = content
        return (panel, layer)
    }

    /// Returns the screen that should host the notch indicators.
    ///
    /// Returns:
    ///   The screen containing the mouse cursor, or the main screen as fallback.
    private static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Computes the notch rectangle from macOS auxiliary top areas.
    ///
    /// Args:
    ///   screen: Screen whose notch geometry should be computed.
    ///
    /// Returns:
    ///   A notch rectangle in global screen coordinates.
    private static func notchGeometry(on screen: NSScreen) -> NSRect {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchWidth = right.origin.x - left.maxX
            if notchWidth > 0 {
                return NSRect(x: left.maxX, y: left.origin.y, width: notchWidth, height: left.height)
            }
        }

        let frame = screen.frame
        let notchHeight = max(screen.safeAreaInsets.top, 24)
        let notchWidthFallback: CGFloat = 162
        return NSRect(
            x: frame.midX - notchWidthFallback / 2,
            y: frame.maxY - notchHeight,
            width: notchWidthFallback,
            height: notchHeight
        )
    }
}

// MARK: - Controller

/// Manages the floating bar panel lifecycle.
/// All visual styling is handled in SwiftUI (FloatingBarView).
@MainActor
final class FloatingBarController {

    private let panel: FloatingBarPanel
    private let notchIndicator = NotchIndicatorController()
    private let state: AppState
    private let barPanelSize: NSSize
    private var panelGeneration = 0

    init(state: AppState) {
        self.state = state

        let inset: CGFloat = 16  // extra room for shadow/glow
        let contentHeight = TF.barHeight + TF.transcriptPopupGap + TF.transcriptPopupMaxHeight
        let frame = NSRect(x: 0, y: 0, width: TF.barWidth + inset * 2, height: contentHeight + inset * 2)
        barPanelSize = frame.size
        panel = FloatingBarPanel(contentRect: frame)

        let barView = FloatingBarView<AppState>(state: state)
        let hosting = NSHostingView(rootView: barView)
        hosting.layer?.backgroundColor = .clear
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.positionAtBottomCenter()

        state.onShowPanel = { [weak self] in self?.show() }
        state.onHidePanel = { [weak self] in self?.hide() }
        state.onUpdatePanelLayout = { [weak self] in self?.updateLayout(animated: true) }
    }

    /// Shows the floating panel using the layout for the current app phase.
    func show() {
        panelGeneration &+= 1
        if state.barPhase == .focusWaiting {
            hideBarPanelImmediately()
            notchIndicator.show()
            return
        }

        showBarPanel()
    }

    /// Shows the regular floating transcription panel.
    private func showBarPanel() {
        notchIndicator.hide()
        panel.contentView?.layer?.removeAllAnimations()
        applyBarPanelLayout(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Hides the floating panel with a short fade-out animation.
    func hide() {
        notchIndicator.hide()
        guard panel.isVisible else { return }
        let expectedGeneration = panelGeneration
        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panelGeneration == expectedGeneration else { return }
                panelRef.orderOut(nil)
            }
        })
    }

    /// Updates panel size and placement to match the current phase.
    ///
    /// Args:
    ///   animated: Whether the size and origin change should be animated.
    private func updateLayout(animated: Bool) {
        if state.barPhase == .focusWaiting {
            panelGeneration &+= 1
            hideBarPanelImmediately()
            notchIndicator.show()
            return
        }
        notchIndicator.hide()
        guard state.barPhase != .hidden else { return }
        if !panel.isVisible {
            showBarPanel()
            return
        }
        applyBarPanelLayout(animated: animated)
    }

    /// Immediately removes the regular bar panel before the notch indicator is shown.
    private func hideBarPanelImmediately() {
        panel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// Applies size and placement for the regular bottom floating panel.
    ///
    /// Args:
    ///   animated: Whether the size and origin change should be animated.
    private func applyBarPanelLayout(animated: Bool) {
        let targetFrame = NSRect(origin: panel.frame.origin, size: barPanelSize)
        let applyFrame = {
            self.panel.setFrame(targetFrame, display: false)
            self.panel.positionAtBottomCenter()
        }
        guard animated, panel.isVisible else {
            applyFrame()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            applyFrame()
        }
    }
}
