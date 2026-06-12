import Foundation

struct CmuxDefaultReplyPolicy: Sendable {
    private let defaultReply: String
    private var focusedTarget: CmuxSurfaceTarget?
    private var focusedTargetHasReplyOpportunity = false
    private var hasUserInput = false
    private var hasSubmittedDefaultReply = false

    /// Creates a policy for blank Return behavior in cmux.
    ///
    /// Args:
    ///   defaultReply: Text sent when a pristine waiting surface receives Return.
    init(defaultReply: String = "Go") {
        self.defaultReply = defaultReply
    }

    /// Marks a cmux surface as newly focused.
    ///
    /// Args:
    ///   target: Focused terminal surface, or `nil` when focus is unavailable.
    ///   hasReplyOpportunity: Whether the surface has an unconsumed agent reply opportunity.
    mutating func updateFocus(target: CmuxSurfaceTarget?, hasReplyOpportunity: Bool) {
        focusedTarget = target
        focusedTargetHasReplyOpportunity = hasReplyOpportunity
        hasUserInput = false
        hasSubmittedDefaultReply = false
    }

    /// Marks that the user has typed in the focused surface.
    mutating func markUserInput() {
        hasUserInput = true
    }

    /// Returns the default reply for a plain Return, when allowed.
    ///
    /// Args:
    ///   target: Current focused terminal surface.
    ///   isPlain: Whether Return has no command/control/option/shift modifiers.
    ///
    /// Returns:
    ///   Default reply text when this Return should be converted into a reply.
    mutating func defaultReplyForPlainReturn(on target: CmuxSurfaceTarget?, isPlain: Bool = true) -> String? {
        guard isPlain,
              let target,
              target == focusedTarget,
              focusedTargetHasReplyOpportunity,
              !hasUserInput,
              !hasSubmittedDefaultReply else {
            return nil
        }
        hasSubmittedDefaultReply = true
        hasUserInput = true
        return defaultReply
    }
}
