import AppKit
import SwiftUI

/// One session count shared by the status item, menu entry, and inbox heading.
struct AgentInboxSummary {
    private static let maximumDisplayedCount = 99
    let count: Int

    /// Counts active or actionable sessions once, independently of unread flags.
    ///
    /// Args:
    ///   items: Provider-qualified, unique rows from the current inbox snapshot.
    init(items: [AgentInboxItem]) {
        count = items.lazy.filter {
            $0.status == .running || $0.status == .waiting || $0.needsAttention
        }.count
    }

    var countText: String {
        count > Self.maximumDisplayedCount ? "\(Self.maximumDisplayedCount)+" : String(count)
    }

    /// Names the destination and carries the same visible count as its status item.
    ///
    /// Args:
    ///   language: Current interface language, resolved on every render.
    ///
    /// Returns:
    ///   A localized menu title, omitting the count when there are no active rows.
    func menuTitle(language: AppLanguage) -> String {
        let title = language == .zh ? "Agent 消息队列" : "Agent Inbox"
        guard count > 0 else { return title }
        return language == .zh ? "\(title)（\(countText)）" : "\(title) (\(countText))"
    }

    /// Explains the exact total without presenting it as an unread-message badge.
    ///
    /// Args:
    ///   language: Current interface language.
    ///
    /// Returns:
    ///   The accessible label and hover description for this inbox snapshot.
    func accessibilityLabel(language: AppLanguage) -> String {
        if language == .zh { return "Agent 消息队列：\(count) 个会话正在工作或待处理" }
        let noun = count == 1 ? "conversation" : "conversations"
        return "Agent Inbox: \(count) \(noun) working or needing attention"
    }
}

/// Menu bar robot silhouette, drawn once and tinted by the native surface.
enum AgentInboxIdentity {
    static let symbol: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let head = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 10),
                                    xRadius: 2.5, yRadius: 2.5)
            head.lineWidth = 1.25
            head.stroke()

            let details = NSBezierPath()
            details.lineWidth = 1.25
            details.lineCapStyle = .round
            for (start, end) in [
                (NSPoint(x: 8, y: 12), NSPoint(x: 8, y: 14)),
                (NSPoint(x: 0.75, y: 6), NSPoint(x: 2, y: 6)),
                (NSPoint(x: 14, y: 6), NSPoint(x: 15.25, y: 6)),
                (NSPoint(x: 6, y: 4.5), NSPoint(x: 10, y: 4.5)),
            ] {
                details.move(to: start)
                details.line(to: end)
            }
            details.stroke()
            for eyeX in [CGFloat(5.25), 10.75] {
                NSBezierPath(ovalIn: NSRect(x: eyeX - 0.9, y: 7.1, width: 1.8, height: 1.8)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 7, y: 13.5, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// A live, counted inbox destination in the native menu, matching the status item.
struct AgentInboxMenuEntry: View {
    @ObservedObject var inbox: AgentInboxStore
    @AppStorage("tf_language") private var languageRaw = AppLanguage.systemDefault
    let onOpen: () -> Void

    var body: some View {
        let language = AppLanguage(rawValue: languageRaw) ?? .en
        let summary = AgentInboxSummary(items: inbox.items)
        Button(action: onOpen) {
            Text(summary.menuTitle(language: language))
        }
        .help(summary.accessibilityLabel(language: language))
    }
}
