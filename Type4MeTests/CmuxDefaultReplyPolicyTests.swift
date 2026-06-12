import XCTest
@testable import Type4Me

final class CmuxDefaultReplyPolicyTests: XCTestCase {
    func testPlainReturnSubmitsDefaultReplyOnlyBeforeUserInput() {
        var policy = CmuxDefaultReplyPolicy()
        let target = CmuxSurfaceTarget(workspaceID: "workspace-1", surfaceID: "surface-1", tty: nil)

        policy.updateFocus(target: target, hasReplyOpportunity: true)

        XCTAssertEqual(policy.defaultReplyForPlainReturn(on: target), "Go")
        XCTAssertNil(policy.defaultReplyForPlainReturn(on: target))
    }

    func testUserInputDisablesDefaultReplyUntilFocusChangesAgain() {
        var policy = CmuxDefaultReplyPolicy()
        let target = CmuxSurfaceTarget(workspaceID: "workspace-1", surfaceID: "surface-1", tty: nil)

        policy.updateFocus(target: target, hasReplyOpportunity: true)
        policy.markUserInput()

        XCTAssertNil(policy.defaultReplyForPlainReturn(on: target))

        policy.updateFocus(target: target, hasReplyOpportunity: true)

        XCTAssertEqual(policy.defaultReplyForPlainReturn(on: target), "Go")
    }

    func testSurfaceWithoutReplyOpportunityDoesNotSubmitDefaultReply() {
        var policy = CmuxDefaultReplyPolicy()
        let target = CmuxSurfaceTarget(workspaceID: "workspace-1", surfaceID: "surface-1", tty: nil)

        policy.updateFocus(target: target, hasReplyOpportunity: false)

        XCTAssertNil(policy.defaultReplyForPlainReturn(on: target))
    }
}
