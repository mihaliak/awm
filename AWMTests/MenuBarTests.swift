import AppKit
import Testing
@testable import AWM

// All tests that install a status item or show native fixture windows share one AppKit host.
@Suite(.serialized) struct NativeWindowTests {
    #if DEBUG
    @Test @MainActor func menuBarExercisesNormalAndReducedMotionAndFirstSetup() async throws {
        try await AppDelegate.verifyMenuBar(reduceMotion: false)
        try await AppDelegate.verifyMenuBar(reduceMotion: true)
        try await AppDelegate.verifyFirstSetup()
    }
    #endif
}

@Test(arguments: [PageEntrance.forward, .backward])
func pageEntranceMovesTowardRestAsItBecomesOpaque(entrance: PageEntrance) {
    let start = entrance.presentation(progress: 0, reduceMotion: false)
    let middle = entrance.presentation(progress: 0.5, reduceMotion: false)
    let end = entrance.presentation(progress: 1, reduceMotion: false)
    #expect(start.offset == (entrance == .forward ? 32 : -32))
    #expect(start.opacity == 0.25)
    #expect(middle.offset == start.offset / 2 && middle.opacity > start.opacity)
    #expect(end.offset == 0 && end.opacity == 1 && end.opacity > middle.opacity)
}

@Test(arguments: [PageEntrance.stationary, .forward, .backward])
func reducedMotionKeepsEveryPageFullyVisible(entrance: PageEntrance) {
    for progress in [0.0, 0.5, 1.0] {
        let state = entrance.presentation(progress: progress, reduceMotion: true)
        #expect(state.offset == 0 && state.opacity == 1)
    }
}

@Test func initialPagePresentationIsAtRest() {
    let state = PageEntrance.stationary.presentation(progress: 0, reduceMotion: false)
    #expect(state.offset == 0 && state.opacity == 1)
}

@Test func statusAnchorUsesTheFullFrameOfANegativeOriginDisplay() {
    let screen = CGRect(x: -900, y: -720, width: 900, height: 720)
    let visible = CGRect(x: -900, y: -706, width: 900, height: 682)
    let button = CGRect(x: -170, y: -24, width: 28, height: 24)
    #expect(PanelGeometry.canAnchor(button, on: screen, visibleFrame: visible))
}

@Test(arguments: [CGRect(x: 110, y: -28, width: 28, height: 24),
                  CGRect(x: 110, y: 0, width: 28, height: 24),
                  CGRect(x: 110, y: 696, width: 0, height: 24),
                  CGRect(x: -28, y: 696, width: 28, height: 24)])
func statusAnchorRejectsAnOffscreenEmptyOrMisplacedButton(button: CGRect) {
    let screen = CGRect(x: 0, y: 0, width: 900, height: 720)
    let visible = CGRect(x: 0, y: 0, width: 900, height: 696)
    #expect(!PanelGeometry.canAnchor(button, on: screen, visibleFrame: visible))
}

@Test func notchStaysBelowTheAnchorAndOnNegativeOriginDisplays() {
    let visible = CGRect(x: -900, y: -160, width: 900, height: 720)
    let left = CGRect(x: -896, y: 560, width: 28, height: 24)
    let right = CGRect(x: -32, y: 560, width: 28, height: 24)
    let center = CGRect(x: -464, y: 560, width: 28, height: 24)

    let size = PanelGeometry.initialSize
    #expect(PanelGeometry.frame(anchor: left, visibleFrame: visible, size: size)
            == CGRect(x: -900, y: 170, width: size.width, height: 390))
    #expect(PanelGeometry.frame(anchor: right, visibleFrame: visible, size: size)
            == CGRect(x: -size.width, y: 170, width: size.width, height: 390))
    #expect(PanelGeometry.frame(anchor: center, visibleFrame: visible, size: size).midX == center.midX)
}

@Test func notchFitsTheUsableAreaOfASmallDisplay() {
    let visible = CGRect(x: 0, y: 50, width: 320, height: 360)
    let anchor = CGRect(x: 275, y: 410, width: 28, height: 24)
    let result = PanelGeometry.frame(anchor: anchor, visibleFrame: visible, size: CGSize(width: 580, height: 590))
    #expect(result == CGRect(x: 0, y: 56, width: 320, height: 354))
}

@Test(arguments: [CGFloat(0), 270, 510, 790])
func notchWidthFitsContentWithinScreenAndDesignLimits(ideal: CGFloat) {
    #expect(PanelGeometry.fittingWidth(ideal, screenWidth: 280) == 280)
    #expect(PanelGeometry.fittingWidth(ideal, screenWidth: 320) == 320)
    #expect(PanelGeometry.fittingWidth(ideal, screenWidth: 450) == min(max(ideal, 320), 450))
    #expect(PanelGeometry.fittingWidth(ideal, screenWidth: 1_440) == min(max(ideal, 320), 680))
    #expect(PanelGeometry.fittingWidth(ideal + 0.25, screenWidth: 1_440) == min(max(ceil(ideal + 0.25), 320), 680))
}

@Test(arguments: [CGFloat(-885), -690, -450, -215, -15])
func panelStaysBelowTheMenuBarAcrossItsWidthRange(anchorX: CGFloat) {
    let visible = CGRect(x: -900, y: -120, width: 900, height: 720)
    let anchor = CGRect(x: anchorX - 14, y: 600, width: 28, height: 24)
    for width in stride(from: 320.0, through: 680.0, by: 12.5) {
        let frame = PanelGeometry.frame(anchor: anchor, visibleFrame: visible,
                                        size: CGSize(width: width, height: 315))
        #expect(frame.maxY == anchor.minY)
        #expect(frame.minX >= visible.minX && frame.maxX <= visible.maxX)
        #expect(frame.minX...frame.maxX ~= anchorX)
    }
}

@Test @MainActor func everyWorkspaceIconHasADrawableSystemSymbol() {
    let missing = WorkspaceIcon.allCases.filter { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) == nil }
    #expect(missing.isEmpty)
}

@Test @MainActor func windowControlHandoffRevealsTheRunningCopyOnEveryRequest() {
    enum Action: Equatable { case settings, finder(URL) }
    var actions: [Action] = []
    let handoff = WindowControlHandoff(
        openSettings: { actions.append(.settings) },
        revealApplication: { actions.append(.finder($0)) }
    )

    handoff.open()
    handoff.open()
    let reveal = Action.finder(Bundle.main.bundleURL)
    #expect(actions == [.settings, reveal, .settings, reveal])
}

#if DEBUG
@Test(arguments: [false, true])
@MainActor func setupConfirmationPersistsUntilAcknowledged(initiallyAuthorized: Bool) throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "com.mihaliak.awm.setup-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    try files.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? files.removeItem(at: directory)
    }
    let store = WorkspaceStore(url: directory.appending(path: ".awm.yaml"))
    let initial = try store.load()
    _ = try store.write(initial.state, replacing: initial)
    let workspace = try Data(contentsOf: store.url)

    func launch(authorized: Bool) -> AppModel {
        let model = AppModel(store: store, errorLog: ErrorLog(url: nil), setupDefaults: defaults)
        model.verificationCapture = WorkspaceSnapshot(displays: DisplayLayout(screens: []),
                                                       members: [], focusedWindow: nil)
        model.verificationAuthorized = authorized
        model.refreshSystemState()
        return model
    }

    let first = launch(authorized: initiallyAuthorized)
    #expect(first.windowControlStage == (initiallyAuthorized ? .ready : .required))
    first.finishWindowControlSetup()
    #expect(first.windowControlStage == (initiallyAuthorized ? .ready : .required))

    let granted = launch(authorized: true)
    let expectedGrantedStage: AppModel.WindowControlStage = initiallyAuthorized ? .ready : .confirmation
    #expect(granted.windowControlStage == expectedGrantedStage)

    let reopened = launch(authorized: true)
    #expect(reopened.windowControlStage == expectedGrantedStage)
    reopened.verificationAuthorized = false
    reopened.finishWindowControlSetup()
    #expect(reopened.windowControlStage == .required)

    let regranted = launch(authorized: true)
    #expect(regranted.windowControlStage == expectedGrantedStage)
    regranted.finishWindowControlSetup()
    #expect(regranted.windowControlStage == .ready)

    #expect(launch(authorized: false).windowControlStage == .required)
    #expect(launch(authorized: true).windowControlStage == .ready)
    #expect(try Data(contentsOf: store.url) == workspace)
    let attributes = try files.attributesOfItem(atPath: store.url.path)
    #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
}
#endif
