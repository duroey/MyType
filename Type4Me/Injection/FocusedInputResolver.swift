import AppKit
import ApplicationServices

/// Resolves the keyboard destination, including panels that do not activate their app.
enum FocusedInputResolver {
    enum Proof: Equatable {
        case system
        case floatingPanel
        case frontmostFallback
    }

    struct Snapshot {
        let application: NSRunningApplication
        let element: AXUIElement?
        let proof: Proof
        var floatingWindow: AXUIElement?
        var floatingWindowID: CGWindowID?
        var floatingWindowFrame: CGRect?
        var foregroundPID: pid_t?
    }

    /// Metadata required before an inactive application's control can own input.
    struct PanelEvidence {
        var ownerMatches = false
        var windowMatches = false
        var matchingWindowCount = 0
        var focusedWindowMatches = false
        var controlIsFocused = false
        var controlIsEditable = false
        var controlIsSecure = false
        var controlIsEnabled = true
        var controlIsInsideWindow = false
        var hitTestMatches = false
    }

    private enum PanelLookup {
        case found(Snapshot)
        case absent
        case unconfirmed
    }

    private static let defaultConfiguration = (try? TextDeliveryConfiguration.bundled()) ?? .init()

    /// Resolves the current destination using the bundled bounds.
    ///
    /// Returns:
    ///   A positively identified input owner, a foreground fallback, or nil when ambiguous.
    static func resolve() -> Snapshot? {
        resolve(configuration: defaultConfiguration)
    }

    /// Resolves focus without reading any input text or activating an application.
    ///
    /// Args:
    ///   configuration: Limits for individual AX calls and the overall panel search.
    /// Returns:
    ///   The current keyboard destination; an unconfirmed floating panel fails closed.
    static func resolve(configuration: TextDeliveryConfiguration) -> Snapshot? {
        let frontmost = frontmostApplication()
        guard AXIsProcessTrusted() else {
            return frontmost.map { Snapshot(application: $0, element: nil, proof: .frontmostFallback) }
        }
        let reader = Reader(configuration: configuration)
        let system = AXUIElementCreateSystemWide()
        if let focused = reader.element("AXFocusedUIElement", from: system),
           let application = application(owning: focused) {
            return Snapshot(application: application, element: focused, proof: .system)
        }
        switch floatingPanel(reader: reader, system: system) {
        case .found(let snapshot): return snapshot
        case .unconfirmed: return nil
        case .absent:
            guard let frontmost, !frontmost.isTerminated else { return nil }
            let app = AXUIElementCreateApplication(frontmost.processIdentifier)
            return Snapshot(
                application: frontmost,
                element: reader.element("AXFocusedUIElement", from: app),
                proof: .frontmostFallback
            )
        }
    }

    /// Returns the app owning current keyboard focus, rather than the menu bar alone.
    static func currentApplication() -> NSRunningApplication? {
        resolve()?.application
    }

    /// Revalidates the original destination before reading or sending to its control.
    ///
    /// Args:
    ///   snapshot: Original input owner and exact control, when exposed.
    ///   configuration: Bounds shared with the delivery operation.
    /// Returns:
    ///   True only while the original target retains sufficient focus evidence.
    static func isCurrent(
        _ snapshot: Snapshot,
        configuration: TextDeliveryConfiguration
    ) -> Bool {
        guard !snapshot.application.isTerminated else { return false }
        let reader = Reader(configuration: configuration)
        if snapshot.proof == .floatingPanel {
            return revalidatePanel(snapshot, reader: reader)
        }
        let system = AXUIElementCreateSystemWide()
        if let current = reader.element("AXFocusedUIElement", from: system) {
            return retainsDestination(
                originalProof: snapshot.proof, currentProof: .system,
                ownerMatches: application(owning: current)?.processIdentifier == snapshot.application.processIdentifier,
                originalHasElement: snapshot.element != nil,
                elementsMatch: snapshot.element.map { CFEqual($0, current) } ?? false
            )
        }
        guard snapshot.proof == .frontmostFallback,
              let current = resolve(configuration: configuration),
              current.proof == .frontmostFallback,
              current.application.processIdentifier == snapshot.application.processIdentifier else { return false }
        guard let original = snapshot.element else { return true }
        return current.element.map { CFEqual($0, original) } ?? false
    }

    /// Revalidates an input snapshot with the bundled focus limits.
    static func isCurrent(_ snapshot: Snapshot) -> Bool {
        isCurrent(snapshot, configuration: defaultConfiguration)
    }

    /// Keeps unavailable normal-app AX metadata distinct from lost floating-panel proof.
    ///
    /// Args:
    ///   originalProof: Evidence captured for the intended destination.
    ///   currentProof: Evidence currently available for the same app.
    ///   ownerMatches: Whether both snapshots identify the same process.
    ///   originalHasElement: Whether a precise control was originally captured.
    ///   elementsMatch: Whether the original and current AX controls are equal.
    /// Returns:
    ///   Whether the destination remains safe for this operation.
    static func retainsDestination(
        originalProof: Proof, currentProof: Proof, ownerMatches: Bool,
        originalHasElement: Bool, elementsMatch: Bool
    ) -> Bool {
        guard ownerMatches else { return false }
        if originalProof == .floatingPanel {
            return currentProof != .frontmostFallback && originalHasElement && elementsMatch
        }
        return originalHasElement ? elementsMatch : currentProof != .floatingPanel
    }

    /// Requires independent window, explicit focus, and visible hit-test evidence together.
    ///
    /// Args:
    ///   evidence: Metadata collected without reading the control's contents.
    /// Returns:
    ///   True only for a uniquely bound, visible, non-secure editable control.
    static func validatesPanel(_ evidence: PanelEvidence) -> Bool {
        evidence.ownerMatches && evidence.windowMatches && evidence.matchingWindowCount == 1
            && evidence.focusedWindowMatches && evidence.controlIsFocused
            && evidence.controlIsEditable && !evidence.controlIsSecure
            && evidence.controlIsEnabled && evidence.controlIsInsideWindow && evidence.hitTestMatches
    }

    /// Rechecks one already identified panel without enumerating unrelated apps or windows.
    private static func revalidatePanel(_ snapshot: Snapshot, reader: Reader) -> Bool {
        guard let original = snapshot.element, let window = snapshot.floatingWindow,
              let windowID = snapshot.floatingWindowID, let expectedFrame = snapshot.floatingWindowFrame,
              frontmostApplication()?.processIdentifier == snapshot.foregroundPID else { return false }
        let system = AXUIElementCreateSystemWide()
        if let focused = reader.element("AXFocusedUIElement", from: system), !CFEqual(focused, original) {
            return false
        }
        let app = AXUIElementCreateApplication(snapshot.application.processIdentifier)
        guard reader.element("AXFocusedUIElement", from: app).map({ CFEqual($0, original) }) == true,
              reader.attribute("AXFocused", from: original) as? Bool == true,
              reader.element("AXWindow", from: original).map({ CFEqual($0, window) }) == true,
              reader.element("AXFocusedWindow", from: app).map({ CFEqual($0, window) }) == true,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = windows.first,
              entry[kCGWindowNumber as String] as? CGWindowID == windowID,
              entry[kCGWindowOwnerPID as String] as? pid_t == snapshot.application.processIdentifier,
              entry[kCGWindowIsOnscreen as String] as? Bool == true,
              let value = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: value as CFDictionary),
              boundsMatch(bounds, expectedFrame, tolerance: reader.configuration.focusWindowMatchTolerance),
              let frame = reader.frame(of: original), validBounds(frame), bounds.contains(frame),
              !reader.expired else { return false }
        reader.setTimeout(on: system)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &hit)
        return result == .success && hit.map { CFEqual($0, original) } == true
            && !reader.expired && reader.attribute("AXFocused", from: original) as? Bool == true
    }

    /// Examines only visible elevated windows, with no traversal of arbitrary text fields.
    private static func floatingPanel(reader: Reader, system: AXUIElement) -> PanelLookup {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return .unconfirmed }
        var candidates = 0
        for entry in windows {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer > 0,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.activationPolicy != .prohibited,
                  let boundsValue = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary),
                  validBounds(bounds),
                  bounds.width >= reader.configuration.minimumFloatingWindowDimension,
                  bounds.height >= reader.configuration.minimumFloatingWindowDimension
            else { continue }
            candidates += 1
            guard candidates <= reader.configuration.maximumFocusWindowCandidates, !reader.expired else {
                return .unconfirmed
            }
            let axApp = AXUIElementCreateApplication(pid)
            guard let focused = reader.element("AXFocusedUIElement", from: axApp),
                  let window = reader.element("AXWindow", from: focused),
                  let frame = reader.frame(of: window),
                  boundsMatch(frame, bounds, tolerance: reader.configuration.focusWindowMatchTolerance)
            else { continue }
            let role = reader.attribute("AXRole", from: focused) as? String ?? ""
            let controlSubrole = reader.attribute("AXSubrole", from: focused) as? String ?? ""
            let editable = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role)
            guard editable else { continue }
            // A tooltip or notification is not keyboard-focus evidence. Only a control
            // explicitly focused inside this visible elevated window becomes a candidate.
            guard reader.attribute("AXFocused", from: focused) as? Bool == true else { continue }
            guard let appWindows = reader.attribute("AXWindows", from: axApp) as? [AXUIElement],
                  appWindows.count <= reader.configuration.maximumFocusWindowCandidates else { return .unconfirmed }
            let matches = appWindows.filter { candidate in
                guard let frame = reader.frame(of: candidate) else { return false }
                return boundsMatch(frame, bounds, tolerance: reader.configuration.focusWindowMatchTolerance)
            }
            guard !reader.expired, matches.count == 1, matches.first.map({ CFEqual($0, window) }) == true else {
                return .unconfirmed
            }
            var evidence = PanelEvidence()
            evidence.ownerMatches = application(owning: focused)?.processIdentifier == pid
            evidence.windowMatches = true
            evidence.matchingWindowCount = matches.count
            evidence.focusedWindowMatches = reader.element("AXFocusedWindow", from: axApp).map {
                CFEqual($0, window)
            } ?? false
            evidence.controlIsFocused = reader.attribute("AXFocused", from: focused) as? Bool == true
            evidence.controlIsEditable = editable && reader.attribute("AXEditable", from: focused) as? Bool != false
            evidence.controlIsSecure = [role, controlSubrole].contains {
                $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password")
            }
            evidence.controlIsEnabled = reader.attribute("AXEnabled", from: focused) as? Bool != false
            guard let controlFrame = reader.frame(of: focused) else { return .unconfirmed }
            evidence.controlIsInsideWindow = validBounds(controlFrame) && bounds.contains(controlFrame)
            guard evidence.controlIsInsideWindow, !reader.expired else { return .unconfirmed }
            var hit: AXUIElement?
            reader.setTimeout(on: system)
            let result = AXUIElementCopyElementAtPosition(system, Float(controlFrame.midX), Float(controlFrame.midY), &hit)
            evidence.hitTestMatches = result == .success && hit.map { CFEqual($0, focused) } == true
            guard validatesPanel(evidence), !reader.expired,
                  reader.attribute("AXFocused", from: focused) as? Bool == true,
                  reader.element("AXFocusedUIElement", from: axApp).map({ CFEqual($0, focused) }) == true
            else { return .unconfirmed }
            return .found(Snapshot(
                application: app, element: focused, proof: .floatingPanel,
                floatingWindow: window, floatingWindowID: windowID,
                floatingWindowFrame: bounds, foregroundPID: frontmostApplication()?.processIdentifier
            ))
        }
        return reader.expired ? .unconfirmed : .absent
    }

    /// Rejects invalid geometry before hit-testing an exact visible control.
    private static func validBounds(_ bounds: CGRect) -> Bool {
        [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
            && bounds.width > 0 && bounds.height > 0
    }

    /// Matches AX and WindowServer rectangles within a configured point tolerance.
    private static func boundsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: Double) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    /// Gets an AX element's owning process without inspecting its text.
    private static func application(owning element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return app
    }

    /// Reads AppKit's foreground app on its owning thread.
    private static func frontmostApplication() -> NSRunningApplication? {
        let read = { NSWorkspace.shared.frontmostApplication }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    /// Bounds AX requests by both a per-call timeout and a shared search deadline.
    private struct Reader {
        let configuration: TextDeliveryConfiguration
        let deadline: TimeInterval
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }

        /// Starts one bounded resolution pass.
        init(configuration: TextDeliveryConfiguration) {
            self.configuration = configuration
            deadline = ProcessInfo.processInfo.systemUptime + configuration.maximumFocusResolutionSeconds
        }

        /// Applies the smaller of the remaining budget and the per-request timeout.
        func setTimeout(on element: AXUIElement) {
            let remaining = max(Double(Float.leastNormalMagnitude), deadline - ProcessInfo.processInfo.systemUptime)
            AXUIElementSetMessagingTimeout(element, Float(min(configuration.accessibilityTimeoutSeconds, remaining)))
        }

        /// Reads an attribute only while the common deadline remains open.
        func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
            guard !expired else { return nil }
            setTimeout(on: element)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        /// Returns only genuine accessibility elements, never unchecked casts.
        func element(_ name: String, from element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(name, from: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        /// Reads a control or window rectangle without requesting its value or title.
        func frame(of element: AXUIElement) -> CGRect? {
            guard let point = attribute("AXPosition", from: element), CFGetTypeID(point) == AXValueGetTypeID(),
                  let size = attribute("AXSize", from: element), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(point, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
            return CGRect(origin: origin, size: dimensions)
        }
    }
}
