import XCTest
@testable import Type4Me

final class FocusedInputResolverTests: XCTestCase {
    private func focusedPanel() -> FocusedInputResolver.PanelEvidence {
        .init(
            ownerMatches: true, windowMatches: true, matchingWindowCount: 1,
            focusedWindowMatches: true, controlIsFocused: true, controlIsEditable: true,
            controlIsSecure: false, controlIsEnabled: true, controlIsInsideWindow: true,
            hitTestMatches: true
        )
    }

    func testInactivePanelCanOwnKeyboardFocusWithoutBeingTheFrontmostApp() {
        XCTAssertTrue(FocusedInputResolver.validatesPanel(focusedPanel()))
    }

    func testCachedBackgroundControlCannotBecomeTheDestination() {
        var evidence = focusedPanel()
        evidence.controlIsFocused = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
        evidence = focusedPanel()
        evidence.hitTestMatches = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
    }

    func testPanelMustBelongToOneVisibleMatchingWindow() {
        for count in [0, 2] {
            var evidence = focusedPanel()
            evidence.matchingWindowCount = count
            XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
        }
        var evidence = focusedPanel()
        evidence.windowMatches = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
        evidence = focusedPanel()
        evidence.focusedWindowMatches = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
    }

    func testObscuredOutOfWindowOrWrongProcessControlIsRejected() {
        var evidence = focusedPanel()
        evidence.controlIsInsideWindow = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
        evidence = focusedPanel()
        evidence.ownerMatches = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
    }

    func testSecureDisabledAndNoneditablePanelControlsAreRejected() {
        var evidence = focusedPanel()
        evidence.controlIsSecure = true
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
        evidence = focusedPanel()
        evidence.controlIsEnabled = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
        evidence = focusedPanel()
        evidence.controlIsEditable = false
        XCTAssertFalse(FocusedInputResolver.validatesPanel(evidence))
    }

    func testLostPanelProofCannotFallBackToAnAppLevelGuess() {
        XCTAssertFalse(FocusedInputResolver.retainsDestination(
            originalProof: .floatingPanel, currentProof: .frontmostFallback,
            ownerMatches: true, originalHasElement: true, elementsMatch: true
        ))
    }

    func testSystemFocusCanConfirmTheSamePanelButNotAnotherControl() {
        XCTAssertTrue(FocusedInputResolver.retainsDestination(
            originalProof: .floatingPanel, currentProof: .system,
            ownerMatches: true, originalHasElement: true, elementsMatch: true
        ))
        XCTAssertFalse(FocusedInputResolver.retainsDestination(
            originalProof: .floatingPanel, currentProof: .system,
            ownerMatches: true, originalHasElement: true, elementsMatch: false
        ))
    }

    func testOpaqueNormalAppFallbackDoesNotAuthorizeAFloatingPanelOrDifferentApp() {
        XCTAssertTrue(FocusedInputResolver.retainsDestination(
            originalProof: .frontmostFallback, currentProof: .frontmostFallback,
            ownerMatches: true, originalHasElement: false, elementsMatch: false
        ))
        XCTAssertFalse(FocusedInputResolver.retainsDestination(
            originalProof: .frontmostFallback, currentProof: .floatingPanel,
            ownerMatches: true, originalHasElement: false, elementsMatch: false
        ))
        XCTAssertFalse(FocusedInputResolver.retainsDestination(
            originalProof: .frontmostFallback, currentProof: .frontmostFallback,
            ownerMatches: false, originalHasElement: false, elementsMatch: false
        ))
    }
}
