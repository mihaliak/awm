import AppKit
import Carbon
import Foundation
import Testing
@testable import AWM

@Test func compositorExcludesOwnInvisibleAndNonWindowSurfaces() {
    let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
    let rows = [
        windowServerRow(100, frame),
        windowServerRow(101, frame, layer: 12),
        windowServerRow(102, frame, alpha: 0),
        windowServerRow(103, .zero),
        windowServerRow(104, frame),
    ]
    let composited = WindowServerRows.composited(rows, excluding: 100)
    #expect(composited.map(\.pid) == [104])
    #expect(composited.map(\.frame) == [frame])
}

@Test func onlyUnaccountedWindowServerRowsMakeAnAppEligibleToReopen() {
    let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
    let nearby = frame.offsetBy(dx: 2, dy: 0)
    let known = windowServerRow(100, nearby, onScreen: false)
    let ignored = [
        windowServerRow(101, frame, onScreen: false),
        windowServerRow(100, frame, layer: 12, onScreen: false),
        windowServerRow(100, frame),
        windowServerRow(100, CGRect(x: 0, y: 0, width: 120, height: 47), onScreen: false),
        windowServerRow(100, .zero, onScreen: false),
    ]
    #expect(!WindowServerRows.hasWithdrawnWindow(in: ignored + [known], pid: 100, knownOffscreenFrames: [frame]))
    #expect(!WindowServerRows.hasWithdrawnWindow(in: ignored + [known, known], pid: 100, knownOffscreenFrames: [frame, frame]))
    #expect(WindowServerRows.hasWithdrawnWindow(in: ignored + [known, known], pid: 100, knownOffscreenFrames: [frame]))
}

@Test func windowlessReopenRequiresEmptyAXListAndNoVisibleWindowSizedSurfaces() {
    let pid: pid_t = 100
    let rows = menuBackingRows(pid: pid)
    let noWindows: [LiveWindow<Int>] = []
    let minimized = [window(1, minimized: true)]
    let frame = CGRect(x: 200, y: 300, width: 500, height: 600)
    let withdrawn = windowServerRow(pid, frame, onScreen: false)

    #expect(WindowServerRows.shouldReopen(pid: pid, knownWindows: noWindows, rows: rows) { true })
    #expect(!WindowServerRows.shouldReopen(pid: pid, knownWindows: noWindows, rows: rows) { false })
    #expect(!WindowServerRows.shouldReopen(pid: pid, knownWindows: noWindows, rows: nil) { true })
    #expect(!WindowServerRows.shouldReopen(pid: pid, knownWindows: minimized, rows: rows) { true })
    #expect(WindowServerRows.shouldReopen(pid: pid, knownWindows: minimized, rows: rows + [withdrawn]) { false })
    for layer in [0, 3] {
        let visible = windowServerRow(pid, frame, layer: layer)
        #expect(!WindowServerRows.shouldReopen(pid: pid, knownWindows: noWindows, rows: rows + [visible]) { true })
    }
}

@Test func primaryCoordinateAnchorPreservesLeftAboveAndBelowDisplays() {
    let rects = [
        CGRect(x: -800, y: 0, width: 800, height: 600),
        CGRect(x: 0, y: 900, width: 1400, height: 900),
        CGRect(x: 0, y: -800, width: 1000, height: 800),
        CGRect(x: 0, y: 0, width: 1200, height: 875)
    ]
    let converted = rects.map { DisplayLayout.accessibilityRect($0, primaryTop: 900) }
    #expect(converted.map(\.origin) == [
        CGPoint(x: -800, y: 300), CGPoint(x: 0, y: -900),
        CGPoint(x: 0, y: 900), CGPoint(x: 0, y: 25)
    ])
    #expect(converted.map(\.size) == rects.map(\.size))
}

@Test func largestIntersectionDeterminesWindowDisplay() {
    let left = display("left", frame: CGRect(x: -900, y: 0, width: 900, height: 900))
    let layout = DisplayLayout(screens: [referenceDisplay, left])
    #expect(layout.display(for: CGRect(x: -320, y: 50, width: 400, height: 400))?.id == left.id)
    #expect(layout.display(for: CGRect(x: -80, y: 50, width: 400, height: 400))?.id == referenceDisplay.id)
    #expect(layout.display(for: CGRect(x: 3000, y: 0, width: 20, height: 20))?.id == referenceDisplay.id)
}

@Test func reconnectUsesOriginalGeometryAndMissingDisplayFallsBackWithoutMutation() throws {
    let left = display("left", frame: CGRect(x: -1800, y: 0, width: 1800, height: 930),
                       usable: CGRect(x: -1780, y: 26, width: 1780, height: 850), uuid: "external")
    let original = DisplayLayout(screens: [referenceDisplay, left])
    let source = saved(window(1, frame: CGRect(x: -1850, y: 60, width: 720, height: 620)), display: left)
    let preferences = Preferences()
    let exact = original.target(for: source, from: original, destinations: original.destinations(from: original),
                                preferences: preferences)
    #expect(exact == source.frame)

    let fallback = try #require(referenceLayout.target(for: source, from: original, destinations: [:],
                                                      preferences: preferences))
    #expect(referenceDisplay.usable.contains(fallback))
    #expect(fallback.minX == referenceDisplay.usable.minX)
    #expect(fallback.width < source.frame.width)

    let reconnected = display("external-new", frame: left.frame, usable: left.usable, uuid: "external")
    let later = DisplayLayout(screens: [referenceDisplay, reconnected])
    #expect(later.matchesArrangement(original))
    #expect(later.target(for: source, from: original, destinations: later.destinations(from: original),
                         preferences: preferences) == source.frame)

    let scaled = display("external-new", frame: CGRect(x: 0, y: -730, width: 1400, height: 730),
                         usable: CGRect(x: 0, y: -700, width: 1400, height: 700), scale: 2, uuid: "external")
    let moved = DisplayLayout(screens: [referenceDisplay, scaled])
    let adjusted = try #require(moved.target(for: source, from: original, destinations: moved.destinations(from: original),
                                              preferences: preferences))
    #expect(scaled.usable.contains(adjusted))
    #expect(!moved.matchesArrangement(original))
    #expect(source.frame.minX == -1850)
}

@Test func restoreUsesDestinationGapAfterMappingMissingOrRescaledDisplay() {
    let external = display("external", frame: CGRect(x: -1000, y: -700, width: 1000, height: 700))
    let original = DisplayLayout(screens: [referenceDisplay, external])
    let window = saved(window(1, frame: external.usable), display: external)
    let scaled = display(external.id, frame: CGRect(x: -800, y: -600, width: 800, height: 600), scale: 2)
    let changed = DisplayLayout(screens: [referenceDisplay, scaled])
    var preferences = Preferences()
    preferences.windowGapUnit = .points
    preferences.windowGapPoints = 128
    #expect(changed.target(for: window, from: original, destinations: changed.destinations(from: original),
                           preferences: preferences) == scaled.usable.insetBy(dx: 48, dy: 48))
    preferences.windowGapUnit = .percentage
    preferences.windowGapPercent = 5
    #expect(referenceLayout.target(for: window, from: original, destinations: [:], preferences: preferences)
            == referenceDisplay.usable.insetBy(dx: 60, dy: 41.25))
}

@Test func matchingUsesReplacementWindowsWithoutContentAndReservesExactGeometry() {
    let first = saved(window(1))
    let second = saved(window(2))
    let atSecond = window(10, frame: second.frame)
    let moved = window(11, frame: first.frame.offsetBy(dx: -70, dy: 0))
    let spare = window(12, frame: CGRect(x: 800, y: 300, width: 100, height: 100))
    let targets = [first.id: first.frame, second.id: second.frame]
    #expect(WorkspaceMatching.windows([first, second], with: [atSecond, moved, spare], targets: targets)
        .map(\.live.handle) == [11, 10])
    #expect(WorkspaceMatching.windows([first, second], with: [atSecond], targets: targets)
        .map(\.saved.id) == [second.id])
}

@Test func identicalHardwareUsesOneToOneArrangementTieBreak() {
    let leftFrame = CGRect(x: -1200, y: 0, width: 1200, height: 900)
    let rightFrame = CGRect(x: 1200, y: 0, width: 1200, height: 900)
    let left = display("previous-left", frame: leftFrame, model: "vendor-model")
    let right = display("previous-right", frame: rightFrame, model: "vendor-model")
    let currentLeft = display("current-left", frame: leftFrame, model: "vendor-model")
    let currentRight = display("current-right", frame: rightFrame, model: "vendor-model")
    let previous = DisplayLayout(screens: [referenceDisplay, left, right])
    let current = DisplayLayout(screens: [referenceDisplay, currentRight, currentLeft])
    let assignment = current.destinations(from: previous)
    #expect(assignment[left.id]?.id == currentLeft.id)
    #expect(assignment[right.id]?.id == currentRight.id)
    #expect(current.matchesArrangement(previous))
}

@Test func privateDisplayMatchingKeepsSerialAndMissingUUIDRules() throws {
    let salt = UUID()
    let frame = CGRect(x: 1200, y: 0, width: 1200, height: 900)
    let original = display("first-port", frame: frame, uuid: "first", model: "vendor-model")
    let replaced = display("second-port", frame: frame, uuid: "second", model: "vendor-model")
    let noUUID = display("second-port", frame: frame, model: "vendor-model")
    let stored = try original.forStorage(salt: salt)
    let savedLayout = DisplayLayout(screens: [stored])
    #expect(DisplayLayout(screens: [replaced]).destinations(from: savedLayout, salt: salt).isEmpty)
    #expect(DisplayLayout(screens: [noUUID]).destinations(from: savedLayout, salt: salt)[stored.id] == noUUID)

    let a = display("left", frame: frame.offsetBy(dx: -2400, dy: 0), uuid: "old-a", model: "vendor-model", serial: 123)
    let b = display("right", frame: frame, uuid: "old-b", model: "vendor-model", serial: 123)
    let storedA = try a.forStorage(salt: salt)
    let storedB = try b.forStorage(salt: salt)
    let first = display("new-left", frame: a.frame, uuid: "new-a", model: "vendor-model", serial: 123)
    let second = display("new-right", frame: b.frame, uuid: "new-b", model: "vendor-model", serial: 123)
    let current = DisplayLayout(screens: [second, first])
    let previous = DisplayLayout(screens: [storedA, storedB])
    let mapped = current.destinations(from: previous, salt: salt)
    #expect(mapped[storedA.id] == first)
    #expect(mapped[storedB.id] == second)
    #expect(current.matchesArrangement(previous, salt: salt))
    #expect(!current.matchesArrangement(previous, salt: UUID()))
}

@Test func horizontalCyclesFollowOrderAndResetOnFocusDirectionAndCenter() throws {
    var cycles = WindowCycles<Int>()
    var preferences = Preferences()
    func target(_ action: ArrangementAction) -> CGRect? {
        let result = cycles.target(action, window: 1, frame: defaultBounds, usable: defaultUsable,
                                   preferences: preferences)
        guard case .frame(let frame) = result else { return nil }
        return frame
    }
    #expect((0..<4).map { _ in target(.left)?.width } == [400, 800, 600, 400])
    #expect(target(.right)?.minX == 800)
    #expect(target(.right)?.minX == 400)
    #expect(target(.left)?.width == 400)
    cycles.focusChanged(to: 2)
    cycles.focusChanged(to: 1)
    #expect(target(.left)?.width == 400)
    _ = target(.center)
    #expect(target(.left)?.width == 400)
    preferences.leftWidths = try [#require(WindowFraction(text: "75%")), #require(WindowFraction(text: "1/4"))]
    cycles.resetEdge()
    #expect(target(.left) == CGRect(x: 0, y: 25, width: 900, height: 825))
    #expect(target(.left)?.width == 300)
    #expect(target(.right)?.width == 400)
}

@Test(arguments: [ArrangementAction.top, .bottom])
func verticalCyclesAnchorToDisplayAndWrap(action: ArrangementAction) {
    var cycles = WindowCycles<Int>()
    let usable = CGRect(x: -950, y: -610, width: 901, height: 751)
    let preferences = Preferences()
    let heights: [CGFloat] = [250, 501, 376, 250]
    for height in heights {
        let target = cycles.target(action, window: 1, frame: defaultBounds, usable: usable, preferences: preferences)
        let y = action == .top ? usable.minY : usable.maxY - height
        #expect(target == .frame(CGRect(x: -950, y: y, width: 901, height: height)))
    }
}

@Test func verticalCyclesUseIndependentPreferencesAndResetOnInterruptions() throws {
    var cycles = WindowCycles<Int>()
    var preferences = Preferences()
    preferences.topHeights = try [#require(WindowFraction(text: "20%")), #require(WindowFraction(text: "100%"))]
    preferences.bottomHeights = try [#require(WindowFraction(text: "40%")), #require(WindowFraction(text: "80%"))]
    let usable = CGRect(x: -600, y: -400, width: 550, height: 500)
    let top = WindowTarget.frame(CGRect(x: -600, y: -400, width: 550, height: 100))
    let bottom = WindowTarget.frame(CGRect(x: -600, y: -100, width: 550, height: 200))
    func target(_ action: ArrangementAction, window: Int = 1) -> WindowTarget {
        cycles.target(action, window: window, frame: defaultBounds, usable: usable, preferences: preferences)
    }
    #expect(target(.top) == top)
    #expect(target(.top) == .frame(usable))
    #expect(target(.bottom) == bottom)
    #expect(target(.bottom) == .frame(CGRect(x: -600, y: -300, width: 550, height: 400)))
    #expect(target(.left) == .frame(CGRect(x: -600, y: -400, width: 183, height: 500)))
    #expect(target(.bottom) == bottom)
    #expect(target(.bottom, window: 2) == bottom)
    #expect(target(.bottom, window: 1) == bottom)
    #expect(target(.center) == .frame(usable.insetBy(dx: 27.5, dy: 25)))
    #expect(target(.bottom) == bottom)
    _ = target(.centerWithoutResizing)
    #expect(target(.bottom) == bottom)
    #expect(target(.center) == .frame(usable))
}

@Test func centerUsesCustomMarginAndAlternatesIndependentlyForEachWindow() {
    var cycles = WindowCycles<Int>()
    var preferences = Preferences()
    #expect(preferences.marginPercent == 5)
    preferences.marginPercent = 10
    let inset = defaultUsable.insetBy(dx: 120, dy: 82.5)
    func center(_ window: Int) -> WindowTarget {
        cycles.target(.center, window: window, frame: defaultBounds, usable: defaultUsable, preferences: preferences)
    }
    #expect(center(1) == .frame(inset))
    #expect(center(2) == .frame(inset))
    #expect(center(1) == .frame(defaultUsable))
    #expect(center(2) == .frame(defaultUsable))
    #expect(center(1) == .frame(inset))
    cycles.removeWindows { $0 == 1 }
    #expect(center(1) == .frame(inset))
}

@Test(arguments: [CGSize(width: 403, height: 305), CGSize(width: 1301, height: 901)])
func moveOnlyCentersOnTheCurrentDisplayEvenWhenTheWindowOverflows(size: CGSize) throws {
    var cycles = WindowCycles<Int>()
    let secondary = display("secondary", frame: CGRect(x: -1100, y: -900, width: 1100, height: 900),
                            usable: CGRect(x: -1075, y: -875, width: 1000, height: 800))
    let layout = DisplayLayout(screens: [referenceDisplay, secondary])
    let frame = CGRect(origin: CGPoint(x: -900, y: -800), size: size)
    let screen = try #require(layout.display(for: frame))
    #expect(screen.id == secondary.id)
    var preferences = Preferences()
    preferences.windowGapPercent = 2
    let target = cycles.target(.centerWithoutResizing, window: 1, frame: frame, usable: screen.usable,
                               preferences: preferences)
    guard case .move(let origin) = target else {
        Issue.record("Expected a position-only placement target.")
        return
    }
    let centered = CGRect(origin: origin, size: size)
    #expect(centered.midX == screen.usable.midX)
    #expect(centered.midY == screen.usable.midY)
    #expect(cycles.target(.centerWithoutResizing, window: 1, frame: centered, usable: screen.usable,
                          preferences: preferences) == target)
}

@Test func sideAndCenteredThirdsShareOneGap() throws {
    var preferences = Preferences()
    preferences.windowGapPercent = 2
    let left = try sizingFrame(.left, preferences: preferences)
    let right = try sizingFrame(.right, preferences: preferences)
    var cycles = WindowCycles<Int>()
    let target = cycles.target(.centerWithoutResizing, window: 1, frame: left, usable: defaultUsable,
                               preferences: preferences)
    guard case .move(let origin) = target else {
        Issue.record("Expected a position-only placement target.")
        return
    }
    let center = CGRect(origin: origin, size: left.size)
    #expect(left.isNear(CGRect(x: 24, y: 41.5, width: 368, height: 792), tolerance: 0.001))
    #expect(abs(center.minX - left.maxX - 24) < 0.001)
    #expect(abs(right.minX - center.maxX - 24) < 0.001)
    #expect(abs(defaultUsable.maxX - right.maxX - 24) < 0.001)
}

@Test(arguments: [0.5, 1.0 / 3, 0.1])
func complementaryTilesKeepOneGapOnBothAxes(fraction: Double) throws {
    var preferences = Preferences()
    preferences.windowGapPercent = 8
    let near = try #require(WindowFraction(fraction))
    let far = try #require(WindowFraction(1 - fraction))
    preferences.leftWidths = [near]
    preferences.rightWidths = [far]
    preferences.topHeights = [near]
    preferences.bottomHeights = [far]
    let usable = CGRect(x: -1321.5, y: -822.25, width: 1221.25, height: 721.5)
    let dx = usable.width * 0.08
    let dy = usable.height * 0.08
    let left = try sizingFrame(.left, preferences: preferences, usable: usable)
    let right = try sizingFrame(.right, preferences: preferences, usable: usable)
    let top = try sizingFrame(.top, preferences: preferences, usable: usable)
    let bottom = try sizingFrame(.bottom, preferences: preferences, usable: usable)
    #expect([left, right, top, bottom].allSatisfy { $0.isUsableWindowFrame })
    #expect(abs(left.minX - usable.minX - dx) < 0.001)
    #expect(abs(right.minX - left.maxX - dx) < 0.001)
    #expect(abs(usable.maxX - right.maxX - dx) < 0.001)
    #expect(abs(top.minY - usable.minY - dy) < 0.001)
    #expect(abs(bottom.minY - top.maxY - dy) < 0.001)
    #expect(abs(usable.maxY - bottom.maxY - dy) < 0.001)
}

@Test(arguments: [
    CGRect(x: 0, y: 25, width: 1200, height: 825),
    CGRect(x: -3000, y: -350, width: 3000, height: 1200)
])
func pointGapsStayTheSameAcrossDisplays(usable: CGRect) throws {
    var preferences = Preferences()
    preferences.windowGapUnit = .points
    preferences.windowGapPercent = 8
    let oneThird = try #require(WindowFraction(text: "1/3"))
    let twoThirds = try #require(WindowFraction(text: "2/3"))
    try expectPointGaps(12, near: oneThird, far: twoThirds, usable: usable, preferences: preferences)
}

@Test func pointsAreCappedUniformlySoMinimumTilesStayPositive() throws {
    var preferences = Preferences()
    preferences.windowGapUnit = .points
    preferences.windowGapPoints = 128
    let usable = CGRect(x: -500, y: 25, width: 500, height: 250)
    let tenth = try #require(WindowFraction(0.1))
    let nineTenths = try #require(WindowFraction(0.9))
    try expectPointGaps(20, near: tenth, far: nineTenths, usable: usable, preferences: preferences)
}

private func expectPointGaps(_ gap: CGFloat, near: WindowFraction, far: WindowFraction, usable: CGRect,
                             preferences: Preferences) throws {
    var preferences = preferences
    preferences.leftWidths = [near]
    preferences.rightWidths = [far]
    preferences.topHeights = [near]
    preferences.bottomHeights = [far]
    let left = try sizingFrame(.left, preferences: preferences, usable: usable)
    let right = try sizingFrame(.right, preferences: preferences, usable: usable)
    let top = try sizingFrame(.top, preferences: preferences, usable: usable)
    let bottom = try sizingFrame(.bottom, preferences: preferences, usable: usable)
    #expect([left, right, top, bottom].allSatisfy { $0.isUsableWindowFrame })
    for tile in [left, right] {
        #expect(abs(tile.minY - usable.minY - gap) < 0.001)
        #expect(abs(usable.maxY - tile.maxY - gap) < 0.001)
    }
    for tile in [top, bottom] {
        #expect(abs(tile.minX - usable.minX - gap) < 0.001)
        #expect(abs(usable.maxX - tile.maxX - gap) < 0.001)
    }
    #expect(abs(left.minX - usable.minX - gap) < 0.001)
    #expect(abs(right.minX - left.maxX - gap) < 0.001)
    #expect(abs(usable.maxX - right.maxX - gap) < 0.001)
    #expect(abs(top.minY - usable.minY - gap) < 0.001)
    #expect(abs(bottom.minY - top.maxY - gap) < 0.001)
    #expect(abs(usable.maxY - bottom.maxY - gap) < 0.001)
}

@Test func pointGapAndPercentageMarginAreComparedPerAxis() throws {
    let usable = CGRect(x: -1120, y: 25, width: 2000, height: 800)
    let full = try #require(WindowFraction(1))
    var preferences = Preferences()
    preferences.windowGapUnit = .points
    preferences.marginPercent = 1
    preferences.leftWidths = [full]
    preferences.rightWidths = [full]
    preferences.topHeights = [full]
    preferences.bottomHeights = [full]
    let filled = usable.insetBy(dx: 12, dy: 12)
    for action: ArrangementAction in [.left, .right, .top, .bottom] {
        #expect(try sizingFrame(action, preferences: preferences, usable: usable) == filled)
    }
    var cycles = WindowCycles<Int>()
    #expect(cycles.target(.center, window: 1, frame: defaultBounds, usable: usable,
                          preferences: preferences) == .frame(usable.insetBy(dx: 20, dy: 12)))
    #expect(cycles.target(.center, window: 1, frame: defaultBounds, usable: usable,
                          preferences: preferences) == .frame(filled))
}

@Test func fullSizeCyclesAndCenterUseTheGapWithoutStackingMargins() throws {
    var preferences = Preferences()
    preferences.windowGapPercent = 2
    let full = try #require(WindowFraction(1))
    preferences.leftWidths = [full]
    preferences.rightWidths = [full]
    preferences.topHeights = [full]
    preferences.bottomHeights = [full]
    let filled = defaultUsable.insetBy(dx: 24, dy: 16.5)
    for action: ArrangementAction in [.left, .right, .top, .bottom] {
        let frame = try sizingFrame(action, preferences: preferences)
        #expect(frame.isNear(filled, tolerance: 0.001))
    }
    for margin in [1, 5] {
        preferences.marginPercent = margin
        var cycles = WindowCycles<Int>()
        let almostFull = cycles.target(.center, window: 1, frame: defaultBounds, usable: defaultUsable,
                                       preferences: preferences)
        let expected = margin == 1 ? filled : defaultUsable.insetBy(dx: 60, dy: 41.25)
        #expect(almostFull == .frame(expected))
        #expect(cycles.target(.center, window: 1, frame: defaultBounds, usable: defaultUsable,
                              preferences: preferences) == .frame(filled))
    }
}

@Test(arguments: WindowGapUnit.allCases)
func zeroGapKeepsTheRoundedFarEdgeHalf(unit: WindowGapUnit) throws {
    var preferences = Preferences()
    preferences.windowGapUnit = unit
    preferences.windowGapPoints = 0
    let half = try #require(WindowFraction(0.5))
    preferences.rightWidths = [half]
    let usable = CGRect(x: -950.5, y: -610.25, width: 901, height: 751)
    let right = try sizingFrame(.right, preferences: preferences, usable: usable)
    #expect(right == CGRect(x: -500.5, y: -610.25, width: 451, height: 751))
}

private func sizingFrame(_ action: ArrangementAction, preferences: Preferences,
                         usable: CGRect = defaultUsable) throws -> CGRect {
    var cycles = WindowCycles<Int>()
    switch cycles.target(action, window: 1, frame: defaultBounds, usable: usable, preferences: preferences) {
    case .frame(let frame): return frame
    case .move: throw WorkspaceError.invalidData
    }
}

@Test(arguments: ["", "0%", "1/0", "-50%", "110%", "nan", "4"])
func invalidWindowFractionsAreRejected(input: String) {
    #expect(WindowFraction(text: input) == nil)
}

extension NativeWindowTests {
    @Test @MainActor func nativeWorkspacePlacementAlignsAnUnresizableWindowWithTheGap() async throws {
        let system = MacWindowSystem()
        let layout = system.displays()
        let display = try #require(layout.primary)
        let screen = try #require(NSScreen.screens.first)
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY,
                                                  width: 300, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        let initial = DisplayLayout.accessibilityRect(window.frame, primaryTop: screen.frame.maxY)
        let ownApp = liveApp("AWMTestHost", pid: getpid())
        let live = try #require(system.windows(for: ownApp, on: nil).first { $0.frame?.isNear(initial) == true })
        let frame = CGRect(x: display.usable.maxX - initial.width, y: initial.minY,
                           width: initial.width, height: initial.height)
        let slot = SavedWindow(id: UUID(), displayID: display.id, frame: frame,
                               relativeFrame: frame.relative(to: display.usable), order: 0)
        var preferences = Preferences()
        preferences.windowGapUnit = .points
        let target = try #require(layout.targets(for: [slot], from: layout, destinations: [display.id: display],
                                                 preferences: preferences)[slot.id])
        let expected = frame.offsetBy(dx: -CGFloat(preferences.windowGapPoints), dy: 0)
        #expect(await system.place(live.handle, in: target, animate: false) == .gapAdjusted(expected))
        let actual = try #require(system.frame(for: live.handle))
        #expect(actual.isNear(expected))
    }

    @Test @MainActor func nativePlacementCentersAndTilesOnlyTheTargetWindow() async throws {
        let system = MacWindowSystem()
        let layout = system.displays()
        let screen = try #require(NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        let initialFrame = CGRect(x: visibleFrame.minX + 20, y: visibleFrame.minY + 20, width: 301, height: 211)
        let target = NSWindow(contentRect: initialFrame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let bystander = NSWindow(contentRect: initialFrame.offsetBy(dx: 35, dy: 35),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        defer {
            target.orderOut(nil)
            bystander.orderOut(nil)
        }
        bystander.orderFrontRegardless()
        target.orderFrontRegardless()

        let ownApp = liveApp("AWMTestHost", pid: getpid())
        let windows = system.windows(for: ownApp, on: nil)
        let targetFrame = DisplayLayout.accessibilityRect(target.frame, primaryTop: screen.frame.maxY)
        let bystanderFrame = DisplayLayout.accessibilityRect(bystander.frame, primaryTop: screen.frame.maxY)
        let moving = try #require(windows.first { $0.frame?.isNear(targetFrame) == true })
        let other = try #require(windows.first { $0.frame?.isNear(bystanderFrame) == true })
        let display = try #require(layout.display(for: targetFrame))
        var cycles = WindowCycles<AXWindow>()
        let preferences = Preferences()
        let centered = cycles.target(.centerWithoutResizing, window: moving.handle, frame: targetFrame,
                                     usable: display.usable, preferences: preferences)
        let result = await system.place(moving.handle, at: centered, animate: true)
        #expect(result == .exact)
        let actual = try #require(system.frame(for: moving.handle))
        #expect(actual.size == targetFrame.size)
        #expect(abs(actual.midX - display.usable.midX) <= 2)
        #expect(abs(actual.midY - display.usable.midY) <= 2)
        #expect(system.frame(for: other.handle) == other.frame)

        for action: ArrangementAction in [.top, .bottom] {
            let frame = try #require(system.frame(for: other.handle))
            let screen = try #require(layout.display(for: frame))
            let tile = cycles.target(action, window: other.handle, frame: frame, usable: screen.usable,
                                     preferences: preferences)
            #expect(await system.place(other.handle, at: tile, animate: false) == .exact)
            let tiled = try #require(system.frame(for: other.handle))
            #expect(abs(tiled.width - screen.usable.width) <= 2)
            #expect(abs(tiled.height - (screen.usable.height / 3).rounded()) <= 2)
            let anchor = action == .top ? tiled.minY - screen.usable.minY : tiled.maxY - screen.usable.maxY
            #expect(abs(anchor) <= 2)
            #expect(system.frame(for: moving.handle) == actual)
        }
    }

    @Test(arguments: [false, true], WindowGapUnit.allCases)
    @MainActor func nativePlacementLeavesOneGapBetweenSideAndCenteredThirds(animate: Bool, unit: WindowGapUnit) async throws {
        let system = MacWindowSystem()
        let screen = try #require(NSScreen.screens.first)
        let usable = try #require(system.displays().primary?.usable)
        let width: CGFloat = 315 + (animate ? 8 : 0) + (unit == .points ? 16 : 0)
        let initial = CGRect(x: screen.visibleFrame.minX + 50, y: screen.visibleFrame.minY + 40, width: width, height: 211)
        let windows = (0..<2).map { offset in
            let window = NSWindow(contentRect: initial.offsetBy(dx: CGFloat(offset * 45), dy: 0),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.orderFrontRegardless()
            return window
        }
        defer { windows.forEach { $0.orderOut(nil) } }

        let live = system.windows(for: liveApp("AWMTestHost", pid: getpid()), on: nil)
        let leftFrame = DisplayLayout.accessibilityRect(windows[0].frame, primaryTop: screen.frame.maxY)
        let middleFrame = DisplayLayout.accessibilityRect(windows[1].frame, primaryTop: screen.frame.maxY)
        let left = try #require(live.first { $0.frame?.isNear(leftFrame) == true })
        let middle = try #require(live.first { $0.frame?.isNear(middleFrame) == true })
        var preferences = Preferences()
        preferences.windowGapUnit = unit
        preferences.windowGapPercent = 2
        var cycles = WindowCycles<AXWindow>()
        for (window, frame, action) in [(left, leftFrame, ArrangementAction.left), (middle, middleFrame, .right)] {
            let target = cycles.target(action, window: window.handle, frame: frame, usable: usable,
                                       preferences: preferences)
            #expect(await system.place(window.handle, at: target, animate: animate) == .exact)
        }
        let middleBefore = try #require(system.frame(for: middle.handle))
        let center = cycles.target(.centerWithoutResizing, window: middle.handle, frame: middleBefore, usable: usable,
                                   preferences: preferences)
        #expect(await system.place(middle.handle, at: center, animate: animate) == .exact)

        let leftAfter = try #require(system.frame(for: left.handle))
        let middleAfter = try #require(system.frame(for: middle.handle))
        let horizontalGap = unit == .points ? 12 : usable.width * 0.02
        let verticalGap = unit == .points ? 12 : usable.height * 0.02
        #expect(middleBefore.size == middleAfter.size)
        #expect(abs(leftAfter.minX - usable.minX - horizontalGap) <= 2)
        #expect(abs(leftAfter.minY - usable.minY - verticalGap) <= 2)
        #expect(abs(usable.maxY - leftAfter.maxY - verticalGap) <= 2)
        #expect(abs(middleAfter.midX - usable.midX) <= 2)
        #expect(abs(middleAfter.minX - leftAfter.maxX - horizontalGap) <= 2)
    }
}

@Test @MainActor func combinedAnimationWritesEachChangedComponentOncePerFrame() async {
    let trace = PlacementTrace()
    let destination = CGRect(x: 220.25, y: 140.75, width: 620.5, height: 420.25)
    #expect(await trace.place(.frame(destination)) == .exact)
    let deadlines = (1...6).map { Duration.milliseconds(16 * $0) }
    #expect(trace.sizes.map(\.time) == deadlines)
    #expect(trace.positions.map(\.time) == deadlines)
    #expect(trace.sizes.first?.value != destination.size)
    #expect(trace.positions.first?.value != destination.origin)
    #expect(trace.frame == destination)
    #expect(trace.reads == 3)
}

@Test @MainActor func resizeMoveAndUnchangedAnimationsOnlyWriteNecessaryComponents() async {
    let resizing = PlacementTrace()
    let size = CGSize(width: 720, height: 420)
    #expect(await resizing.place(.frame(CGRect(origin: resizing.frame.origin, size: size))) == .exact)
    #expect(resizing.positions.isEmpty)
    #expect(resizing.sizes.count == 6)

    let moving = PlacementTrace()
    let position = CGPoint(x: 340, y: 240)
    #expect(await moving.place(.move(position)) == .exact)
    #expect(moving.positions.count == 6)
    #expect(moving.sizes.isEmpty)

    let unchanged = PlacementTrace()
    #expect(await unchanged.place(.frame(unchanged.frame)) == .exact)
    #expect(unchanged.sizes.isEmpty && unchanged.positions.isEmpty)
    #expect(unchanged.reads == 1)
}

@Test @MainActor func placementOmitsAnimationAndRetriesAClampedSizeOnceAfterMoving() async {
    let trace = PlacementTrace()
    let destination = CGRect(x: 220.5, y: 140.5, width: 620.5, height: 420.5)
    trace.adjustSize = { current, proposed in
        current.origin == destination.origin ? proposed : CGSize(width: 400, height: proposed.height)
    }
    #expect(await trace.place(.frame(destination), animate: false) == .exact)
    #expect(trace.sizes.map(\.time) == [.zero, .milliseconds(25)])
    #expect(trace.positions.map(\.time) == [.zero])
    #expect(trace.frame == destination)

    let constrained = PlacementTrace()
    constrained.adjustSize = { _, proposed in CGSize(width: 400, height: proposed.height) }
    #expect(await constrained.place(.frame(destination), animate: false) == .constrained)
    #expect(constrained.sizes.count == 2)
    #expect(constrained.positions.count == 1)
}

@Test @MainActor func animationCoalescesMissedFramesAndCancellationSkipsFinalWrite() async {
    let destination = CGRect(x: 220, y: 140, width: 620, height: 420)
    let slow = PlacementTrace()
    slow.adjustSize = { [weak slow] _, proposed in
        if let slow, slow.sizes.count == 1 { slow.time += .milliseconds(55) }
        return proposed
    }
    #expect(await slow.place(.frame(destination)) == .exact)
    #expect(slow.sizes.map(\.time) == [16, 71, 80, 96].map { Duration.milliseconds($0) })
    #expect(slow.frame == destination)

    let cancelled = PlacementTrace()
    cancelled.onSleep = { deadline in
        if deadline == .milliseconds(32) { withUnsafeCurrentTask { $0?.cancel() } }
    }
    let placement = Task { await cancelled.place(.frame(destination)) }
    #expect(await placement.value == .unavailable)
    #expect(cancelled.sizes.count == 1 && cancelled.positions.count == 1)
    #expect(cancelled.frame != destination)
}

@Test @MainActor func cancelledSettleDoesNotCorrectAndMoveOnlyNeverWritesSize() async {
    let cancelled = PlacementTrace()
    let destination = CGRect(x: 220, y: 140, width: 620, height: 420)
    cancelled.adjustSize = { _, proposed in CGSize(width: 400, height: proposed.height) }
    cancelled.onSleep = { _ in withUnsafeCurrentTask { $0?.cancel() } }
    let placement = Task { await cancelled.place(.frame(destination), animate: false) }
    #expect(await placement.value == .unavailable)
    #expect(cancelled.sizes.count == 1 && cancelled.positions.count == 1)

    let move = PlacementTrace()
    move.adjustPosition = { current, proposed in
        CGRect(origin: proposed, size: CGSize(width: current.width + 10, height: current.height))
    }
    #expect(await move.place(.move(destination.origin), animate: false) == .constrained)
    #expect(move.positions.count == 1)
    #expect(move.sizes.isEmpty)
}

@MainActor
private final class PlacementTrace {
    var frame = CGRect(x: 50, y: 60, width: 300, height: 250)
    var time: Duration = .zero
    var reads = 0
    var positions: [(time: Duration, value: CGPoint)] = []
    var sizes: [(time: Duration, value: CGSize)] = []
    var adjustSize: ((CGRect, CGSize) -> CGSize)?
    var adjustPosition: ((CGRect, CGPoint) -> CGRect)?
    var onSleep: ((Duration) -> Void)?

    func place(_ target: WindowTarget, animate: Bool = true, gap: WorkspaceWindowTarget.Gap? = nil) async -> Placement {
        let writer = WindowPlacement(
            readFrame: {
                self.reads += 1
                return self.frame
            },
            setPosition: { position in
                self.positions.append((self.time, position))
                self.frame = self.adjustPosition?(self.frame, position) ?? CGRect(origin: position, size: self.frame.size)
                return true
            },
            setSize: { size in
                self.sizes.append((self.time, size))
                self.frame.size = self.adjustSize?(self.frame, size) ?? size
                return true
            }
        )
        let timing = WindowPlacement.Timing(now: { self.time }, sleepUntil: { deadline in
            self.time = deadline
            self.onSleep?(deadline)
        })
        return await writer.place(target, animate: animate, timing: timing, gap: gap)
    }
}

@Test(arguments: [false, true]) @MainActor
func workspacePlacementHonorsTheGapWithAFixedWidthWindow(atRightEdge: Bool) async throws {
    let bounds = CGRect(x: -1819, y: -1500, width: 1420, height: 950)
    let external = display("external", frame: bounds, primary: true)
    let layout = DisplayLayout(screens: [external])
    let size = CGSize(width: 400, height: 685)
    let original = CGRect(x: atRightEdge ? bounds.maxX - size.width : bounds.minX, y: -1381,
                          width: size.width, height: size.height)
    let slot = saved(window(1, frame: original), display: external)
    var preferences = Preferences()
    preferences.windowGapUnit = .percentage
    preferences.windowGapPercent = 1
    let target = try #require(layout.targets(for: [slot], from: layout, destinations: [external.id: external],
                                             preferences: preferences)[slot.id])
    let gap = bounds.width * 0.01
    #expect(abs(target.frame.width - (size.width - gap)) < 0.01)
    let expected = CGRect(x: atRightEdge ? original.minX - gap : original.minX + gap, y: original.minY,
                          width: size.width, height: size.height)
    let fixed = PlacementTrace()
    fixed.frame = original.offsetBy(dx: 80, dy: 60)
    fixed.adjustSize = { frame, requested in CGSize(width: frame.width, height: requested.height) }
    for _ in 0..<2 {
        #expect(await fixed.place(.frame(target.frame), animate: false, gap: target.gap) == .gapAdjusted(expected))
        #expect(fixed.frame.isNear(expected, tolerance: 0.01))
    }
    let resizable = PlacementTrace()
    resizable.frame = original
    #expect(await resizable.place(.frame(target.frame), animate: false, gap: target.gap) == .exact)
    #expect(resizable.frame == target.frame)
}

@Test func matchingUsesVisibleWindowsFirstAndBreaksIdenticalGeometryTiesInInputOrder() throws {
    let frame = try #require(window(1).frame)
    let first = saved(window(1, frame: frame, order: 0))
    let second = saved(window(2, frame: frame, order: 0))
    let candidates = [window(8, visible: false, frame: frame, order: 0),
                      window(9, frame: frame.offsetBy(dx: 10, dy: 0), order: 0),
                      window(10, frame: frame.offsetBy(dx: 10, dy: 0), order: 0)]
    let mapped = frame.offsetBy(dx: -1000, dy: 0)
    let targets = [first.id: mapped, second.id: mapped]
    let result = WorkspaceMatching.windows([first, second], with: candidates, targets: targets)
    #expect(result.map(\.live.handle) == [9, 10])
    let acrossDisplays = WorkspaceMatching.windows([first], with: [window(11, frame: frame), window(12, frame: mapped)],
                                                    targets: targets)
    #expect(acrossDisplays.map(\.live.handle) == [12])
}

@Test func shortcutDefaultsConflictsDisableAndPresetRemoval() throws {
    var state = AppState()
    #expect(state.shortcuts.map(\.key.code) == [
        UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow), UInt32(kVK_Return),
        UInt32(kVK_UpArrow), UInt32(kVK_DownArrow), UInt32(kVK_ANSI_C)
    ])
    #expect(state.shortcuts.allSatisfy { $0.key.modifiers == UInt32(cmdKey | optionKey) })
    let center = try #require(state.shortcuts.first { $0.action == .arrange(.center) })
    #expect(center.key.label == "⌥⌘ Enter")
    #expect(Set(state.shortcuts.map(\.action)) == Set(ArrangementAction.allCases.map { .arrange($0) }))
    #expect(ArrangementAction.top.label == "Align top")
    #expect(ArrangementAction.bottom.label == "Align bottom")
    #expect(ArrangementAction.centerWithoutResizing.label == "Center without resizing")
    let current = try #require(state.shortcuts.first?.key)
    let member = SavedApp(identity: identity("Writer"), windows: [saved(window(1))])
    let created = try state.save(name: " Work ", snapshot: preset([member]).snapshot)
    #expect(created.name == "Work")
    #expect(throws: ShortcutError.self) { try state.assign(current, to: .preset(created.id)) }
    #expect(state.shortcuts == KeyboardBinding.defaults)
    try state.assign(nil, to: .arrange(.left))
    try state.assign(current, to: .preset(created.id))
    #expect(state.shortcuts.contains { $0.action == .preset(created.id) && $0.key == current })
    try state.delete(created.id)
    #expect(!state.shortcuts.contains { $0.key == current })
    #expect(HotKey(code: UInt32(kVK_ANSI_A), modifiers: 0) == nil)
    #expect(HotKey(code: UInt32(kVK_Command), modifiers: UInt32(cmdKey)) == nil)
}

@Test func resetPreservesPresetKeysAndReportsDefaultConflicts() throws {
    var state = AppState()
    let left = try #require(KeyboardBinding.defaults.first)
    let member = SavedApp(identity: identity("Writer"), windows: [saved(window(1))])
    let created = try state.save(name: "Work", snapshot: preset([member]).snapshot)
    try state.assign(nil, to: left.action)
    try state.assign(left.key, to: .preset(created.id))
    let before = state.shortcuts
    #expect(throws: ShortcutError.self) { try state.resetWindowShortcuts() }
    #expect(state.shortcuts == before)
    let dedicated = try #require(HotKey(code: UInt32(kVK_F17), modifiers: UInt32(cmdKey)))
    try state.assign(dedicated, to: .preset(created.id))
    try state.resetWindowShortcuts()
    #expect(KeyboardBinding.defaults.allSatisfy(state.shortcuts.contains))
    #expect(state.shortcuts.contains(KeyboardBinding(action: .preset(created.id), key: dedicated)))
}

@Test func reconnectMatchesHardwareSerialWhenSystemUUIDChanges() {
    let previous = display("previous", uuid: "first-port", model: "Vendor:Model", serial: 408)
    let current = display("current", uuid: "second-port", model: "Vendor:Model", serial: 408)
    let other = display("other", uuid: "other-port", model: "Vendor:Model", serial: 409)
    let old = DisplayLayout(screens: [referenceDisplay, previous])
    let new = DisplayLayout(screens: [referenceDisplay, other, current])
    #expect(new.destinations(from: old)[previous.id]?.id == current.id)
}

@Test(arguments: WindowGapUnit.allCases)
@MainActor func centeredWindowKeepsItsFrameAcrossFocusChanges(unit: WindowGapUnit) async throws {
    let system = MacWindowSystem()
    let screen = try #require(NSScreen.screens.first)
    let usable = try #require(system.displays().primary?.usable)
    let initial = CGRect(x: screen.visibleFrame.minX + 146, y: screen.visibleFrame.minY + 83,
                         width: unit == .points ? 377 : 389, height: 249)
    let window = NSWindow(contentRect: initial, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
    let other = NSWindow(contentRect: initial.offsetBy(dx: 52, dy: 30), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
    defer {
        window.orderOut(nil)
        other.orderOut(nil)
    }
    window.makeKeyAndOrderFront(nil)
    other.orderFrontRegardless()
    let ownApp = liveApp("AWMTestHost", pid: getpid())
    let nativeFrame = DisplayLayout.accessibilityRect(window.frame, primaryTop: screen.frame.maxY)
    let moving = try #require(system.windows(for: ownApp, on: nil).first { $0.frame?.isNear(nativeFrame) == true })
    var preferences = Preferences()
    preferences.windowGapUnit = unit
    preferences.windowGapPoints = 20
    preferences.windowGapPercent = 2
    preferences.marginPercent = 6
    var cycles = WindowCycles<AXWindow>()
    let centered = cycles.target(.center, window: moving.handle, frame: nativeFrame,
                                 usable: usable, preferences: preferences)
    #expect(await system.place(moving.handle, at: centered, animate: true) == .exact)
    let almostFull = try #require(system.frame(for: moving.handle))
    #expect(almostFull.isNear(usable.insetBy(dx: usable.width * 0.06, dy: usable.height * 0.06)))

    other.makeKey()
    cycles.focusChanged(to: nil)
    window.makeKey()
    cycles.focusChanged(to: moving.handle)
    #expect(system.frame(for: moving.handle) == almostFull)

    let filled = cycles.target(.center, window: moving.handle, frame: almostFull,
                               usable: usable, preferences: preferences)
    #expect(await system.place(moving.handle, at: filled, animate: false) == .exact)
    let fillWithGap = try #require(system.frame(for: moving.handle))
    let (horizontal, vertical) = preferences.windowGaps(in: usable)
    #expect(fillWithGap.isNear(usable.insetBy(dx: horizontal, dy: vertical)))

    window.setFrame(window.frame.insetBy(dx: 25, dy: 33), display: false)
    let manuallyResized = try #require(system.frame(for: moving.handle))
    #expect(manuallyResized != fillWithGap)
    other.makeKey()
    cycles.focusChanged(to: nil)
    window.makeKey()
    cycles.focusChanged(to: moving.handle)
    #expect(system.frame(for: moving.handle) == manuallyResized)
}
