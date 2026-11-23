import AppKit
#if DEBUG
import Carbon
#endif
import SwiftUI

@MainActor
private final class StatusPanel: NSPanel {
    var cancel: (() -> Void)?
    var pendingContentSize: CGSize?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        cancel?()
    }
}

enum PanelGeometry {
    static let initialSize = CGSize(width: 320, height: 390)
    static let maximumWidth: CGFloat = 680
    static let maximumHeight: CGFloat = 530
    static let topInset: CGFloat = 4

    static func fittingWidth(_ naturalWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(max(ceil(naturalWidth), initialSize.width), maximumWidth, screenWidth)
    }

    static func leadingEdge(anchorX: CGFloat, visibleFrame: CGRect, width: CGFloat) -> CGFloat {
        min(max(anchorX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
    }

    static func canAnchor(_ button: CGRect, on screen: CGRect, visibleFrame: CGRect) -> Bool {
        let top = min(button.minY, visibleFrame.maxY)
        let headerAndBody = topInset + MenuMetrics.headerHeight + MenuMetrics.headerBottomInset + 6
        return !button.intersection(screen).isEmpty && top - visibleFrame.minY > headerAndBody
    }

    static func frame(anchor: CGRect, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let top = min(anchor.minY, visibleFrame.maxY)
        let height = min(size.height, maximumHeight, max(1, top - visibleFrame.minY - 6))
        let left = leadingEdge(anchorX: anchor.midX, visibleFrame: visibleFrame, width: width)
        return CGRect(x: left, y: top - height, width: width, height: height)
    }
}

@MainActor
final class StatusPopover: NSObject {
    private struct StatusAnchor {
        let button: CGRect
        let screen: NSScreen
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let windowControl: WindowControlHandoff
    private var panel: StatusPanel?
    private var closingPanel: StatusPanel?
    private var resizeTask: Task<Void, Never>?
    private var targetFrame: CGRect?
    private var anchor: CGRect = .zero
    private var visibleFrame: CGRect = .zero
    private var frontPID: pid_t?
    private var previousApp: NSRunningApplication?
    private var workspaceActivation: (any NSObjectProtocol)?
    private var globalClicks: Any?
    private var localClicks: Any?
    private var isInstalled = true
    private let reduceMotion: () -> Bool

    #if DEBUG
    private var isVerifying = false
    private var verificationRegions: [String: CGRect] = [:]
    private var verificationURLs: [URL] = []
    private let verificationHover = MenuHoverProbe()
    private var verificationMotion: [[MenuMotionSample]] = []
    private var verificationPages: [TimedPage] = []
    private var verificationResizeFrames: [CGRect] = []
    private var verificationFitRequests: [CGRect] = []
    private var verificationSnapshotDirectory: URL?
    #endif

    init(model: AppModel, windowControl: WindowControlHandoff? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.model = model
        self.reduceMotion = reduceMotion
        self.windowControl = windowControl ?? WindowControlHandoff(openSettings: model.openPermissionSettings)
        super.init()
        #if DEBUG
        if model.verificationCapture == nil { item.autosaveName = AWMIdentity.statusItemName }
        #else
        item.autosaveName = AWMIdentity.statusItemName
        #endif
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel(AWMIdentity.displayName)
        item.button?.toolTip = AWMIdentity.displayName
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        item.button?.title = ""
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
    }

    private var statusAnchor: StatusAnchor? {
        guard let button = item.button, let window = button.window, window.isVisible else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.screens.first { !$0.frame.intersection(rect).isEmpty }
        guard let screen, PanelGeometry.canAnchor(rect, on: screen.frame, visibleFrame: screen.visibleFrame) else {
            return nil
        }
        return StatusAnchor(button: rect, screen: screen)
    }

    @objc private func toggle() {
        if panel != nil {
            dismiss(restoreFocus: true)
            return
        }
        finishClosingPanel()
        guard let statusAnchor else { return }
        anchor = statusAnchor.button
        visibleFrame = statusAnchor.screen.visibleFrame
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        model.refreshSystemState()
        previousApp = model.lastExternalPID.flatMap { NSRunningApplication(processIdentifier: $0) }

        let frame = PanelGeometry.frame(anchor: anchor, visibleFrame: visibleFrame, size: PanelGeometry.initialSize)
        let panel = StatusPanel(contentRect: frame,
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityLabel(AWMIdentity.displayName)
        panel.cancel = { [weak self] in self?.dismiss(restoreFocus: true) }
        self.panel = panel
        let root = PopoverRoot(
            model: model, focusedPID: previousApp?.processIdentifier,
            visibleFrame: visibleFrame, reducePanelMotion: reduceMotion(),
            allowWindowControl: { [weak self] in self?.allowWindowControl() },
            quit: { NSApp.terminate(nil) },
            fitContent: { [weak self, weak panel] size in
                guard let self, let panel, self.panel === panel else { return }
                self.scheduleFit(panel, size: size)
            }
        )
        #if DEBUG
        var verifiedRoot = root
        if isVerifying { verifiedRoot.verification = verification(for: panel) }
        let host = NSHostingView(rootView: verifiedRoot)
        #else
        let host = NSHostingView(rootView: root)
        #endif
        host.sizingOptions = []
        panel.contentView = host

        let reduceMotion = reduceMotion()
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        // Clear the focus chosen by AppKit when it makes the panel key.
        panel.makeFirstResponder(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.19
                panel.animator().alphaValue = 1
            }
        }
        monitorDismissal(of: panel)
    }

    private func scheduleFit(_ panel: StatusPanel, size: CGSize) {
        let scheduled = panel.pendingContentSize != nil
        panel.pendingContentSize = size
        guard !scheduled else { return }
        // Collect the latest fit and reframe after the SwiftUI layout pass.
        Task { @MainActor [weak self, weak panel] in
            guard let self, let panel, self.panel === panel, let size = panel.pendingContentSize else { return }
            panel.pendingContentSize = nil
            self.resize(panel, size: size)
        }
    }

    private func resize(_ panel: StatusPanel, size: CGSize) {
        let frame = PanelGeometry.frame(anchor: anchor, visibleFrame: visibleFrame, size: size)
        guard frame != targetFrame else { return }
        let start = panel.frame.size
        let animate = targetFrame != nil && start.width != frame.width && !reduceMotion()
        targetFrame = frame
        #if DEBUG
        if isVerifying && panel.frame != frame { verificationFitRequests.append(frame) }
        #endif
        resizeTask?.cancel()
        resizeTask = nil
        guard animate else {
            applyFit(panel, frame: frame)
            return
        }

        resizeTask = Task { @MainActor [weak self, weak panel] in
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self, let panel, self.panel === panel else { return }
                let fraction = (ProcessInfo.processInfo.systemUptime - began) / 0.19
                if fraction >= 1 || self.reduceMotion() {
                    self.applyFit(panel, frame: frame)
                    self.resizeTask = nil
                    return
                }
                let progress = 1 - pow(1 - fraction, 3)
                let size = CGSize(width: start.width + (frame.width - start.width) * progress,
                                  height: start.height + (frame.height - start.height) * progress)
                let step = PanelGeometry.frame(anchor: self.anchor, visibleFrame: self.visibleFrame, size: size)
                self.applyFit(panel, frame: step)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func applyFit(_ panel: StatusPanel, frame: CGRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        #if DEBUG
        if isVerifying { verificationResizeFrames.append(panel.frame) }
        #endif
    }

    private func allowWindowControl() {
        guard panel != nil, !model.authorized else { return }
        dismiss(restoreFocus: false, animated: false)
        windowControl.open()
    }

    private func monitorDismissal(of shownPanel: StatusPanel) {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClicks = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel && event.window !== self.item.button?.window {
                self.dismiss(restoreFocus: false)
            }
            return event
        }
        #if DEBUG
        // Keep the fixture independent of live desktop input and app switches.
        if isVerifying { return }
        #endif
        globalClicks = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self, weak shownPanel] _ in
            Task { @MainActor in
                guard let self, let shownPanel, self.panel === shownPanel else { return }
                self.dismiss(restoreFocus: false)
            }
        }
        workspaceActivation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self, weak shownPanel] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, let shownPanel, self.panel === shownPanel,
                      let pid, pid != getpid(), pid != self.frontPID else { return }
                self.dismiss(restoreFocus: false)
            }
        }
    }

    private func dismiss(restoreFocus: Bool, animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        resizeTask?.cancel()
        resizeTask = nil
        targetFrame = nil
        if let globalClicks { NSEvent.removeMonitor(globalClicks) }
        if let localClicks { NSEvent.removeMonitor(localClicks) }
        if let workspaceActivation { NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivation) }
        globalClicks = nil
        localClicks = nil
        workspaceActivation = nil
        frontPID = nil
        model.stopRecording()

        panel.ignoresMouseEvents = true
        if animated && !reduceMotion() {
            closingPanel = panel
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.11
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, let panel, self.closingPanel === panel else { return }
                    self.finishClosingPanel()
                }
            }
        } else {
            panel.orderOut(nil)
        }
        if restoreFocus, model.restoringID == nil, NSApp.isActive,
           let previousApp, !previousApp.isTerminated, !previousApp.isHidden {
            if #available(macOS 14, *) {
                NSApp.yieldActivation(to: previousApp)
                previousApp.activate(from: .current, options: [])
            } else {
                previousApp.activate(options: [.activateIgnoringOtherApps])
            }
        }
        previousApp = nil
    }

    private func finishClosingPanel() {
        closingPanel?.orderOut(nil)
        closingPanel = nil
    }

    func displayConfigurationChanged() {
        finishClosingPanel()
        dismiss(restoreFocus: false, animated: false)
    }

    func uninstall() {
        guard isInstalled else { return }
        isInstalled = false
        dismiss(restoreFocus: false, animated: false)
        finishClosingPanel()
        NSStatusBar.system.removeStatusItem(item)
    }

    #if DEBUG
    enum VerificationHandoff: Equatable {
        case settings
        case finder(URL)
    }

    struct VerificationFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw VerificationFailure(message: description) }
        print("OK: \(description)")
    }

    private enum ClickPosition { case center, leading, trailing }

    private struct FixtureClick {
        let time: TimeInterval
        let region: CGRect
        let pointInWindow: CGPoint
    }

    private struct TimedPage {
        let time: TimeInterval
        let presentations: [MenuPagePresentation]
    }

    private var presentedPage: MenuPagePresentation? {
        guard let pages = verificationPages.last?.presentations, pages.count == 1 else { return nil }
        return pages.first
    }

    private func waitUntil(_ description: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition() {
            guard clock.now < deadline else { throw VerificationFailure(message: description()) }
            try await clock.sleep(for: .milliseconds(16))
        }
    }

    private func settleMenu() async throws {
        // Let the native host commit the action's first layout before checking its target size.
        try await Task.sleep(for: .milliseconds(32))
        try await waitUntil("menu did not settle (page \(String(describing: presentedPage)), frame \(String(describing: panel?.frame)), target \(String(describing: targetFrame)))") {
            guard let panel else { return true }
            guard let targetFrame, let header = verificationRegions["Page header"] else { return false }
            return presentedPage?.opacity == 1 && resizeTask == nil && panel.pendingContentSize == nil
                && abs(targetFrame.width - panel.frame.width) <= 1 && abs(targetFrame.height - panel.frame.height) <= 1
                && abs(header.width - panel.frame.width) <= 1 && abs(header.height - MenuMetrics.headerHeight) < 0.01
        }
    }

    private func waitForEntrance(_ page: PopoverPage, direction: PageEntrance) async throws {
        try await waitUntil("did not see \(page.title) \(reduceMotion() ? "at rest" : "in flight")") {
            guard let presentedPage, presentedPage.surface == .page(page) else { return false }
            if reduceMotion() { return presentedPage.offset == 0 && presentedPage.opacity == 1 }
            let signedOffset = direction == .forward ? presentedPage.offset : -presentedPage.offset
            return signedOffset >= 8 && presentedPage.opacity > 0.25 && presentedPage.opacity < 1
        }
    }

    private func region(_ name: String) throws -> CGRect {
        guard let frame = verificationRegions[name] else {
            throw VerificationFailure(message: "missing fixture region \(name)")
        }
        return frame
    }

    // Send events only to this process’s test panel. No desktop input or Accessibility grant is needed.
    private func click(_ name: String, at position: ClickPosition = .center) async throws {
        _ = try await dispatchClick(name, at: position)
        try await settleMenu()
    }

    private func dispatchClick(_ name: String, at position: ClickPosition = .center,
                               events: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]) async throws -> FixtureClick {
        guard let panel else { throw VerificationFailure(message: "panel unavailable for fixture click") }
        let rect = try await visibleRegion(name, in: panel)
        guard let view = panel.contentView else { throw VerificationFailure(message: "fixture host unavailable") }
        let x: CGFloat
        switch position {
        case .center: x = rect.midX
        case .leading: x = rect.minX + 8
        case .trailing: x = rect.maxX - 12
        }
        let localPoint = CGPoint(x: view.bounds.minX + x,
                                 y: view.isFlipped ? view.bounds.minY + rect.midY : view.bounds.maxY - rect.midY)
        let point = view.convert(localPoint, to: nil)
        guard view.bounds.contains(localPoint) else {
            throw VerificationFailure(message: "fixture click for \(name) lies outside the panel: \(rect)")
        }
        let began = ProcessInfo.processInfo.systemUptime
        for type in events {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw VerificationFailure(message: "fixture mouse event unavailable")
            }
            NSApp.sendEvent(event)
        }
        return FixtureClick(time: began, region: rect, pointInWindow: point)
    }

    private func visibleRegion(_ name: String, in panel: StatusPanel) async throws -> CGRect {
        guard let view = panel.contentView else { throw VerificationFailure(message: "fixture host unavailable") }
        func measure() {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        try await waitUntil("fixture region \(name) unavailable in \(String(describing: presentedPage?.surface))") {
            guard self.panel === panel, panel.isVisible else { return false }
            measure()
            return verificationRegions[name] != nil && verificationRegions["Page header"] != nil
        }
        let rect = try region(name)
        let header = try region("Page header")
        if header.contains(rect) { return rect }
        let bodyTop = header.maxY + MenuMetrics.headerBottomInset
        let bottom = view.bounds.height
        if !(bodyTop..<bottom).contains(rect.midY),
           let scroll = findScrollView(view) {
            let clip = scroll.contentView
            let shift = rect.midY - (bodyTop + bottom) / 2
            let point = CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + (clip.isFlipped ? shift : -shift))
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: point, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }
        try await waitUntil("fixture region \(name) is outside the scrolling area: \(String(describing: verificationRegions[name])), panel \(panel.frame)") {
            guard self.panel === panel, panel.isVisible else { return false }
            measure()
            guard let current = verificationRegions[name], let header = verificationRegions["Page header"] else { return false }
            return current.midY >= header.maxY + MenuMetrics.headerBottomInset && current.midY < view.bounds.height
        }
        return try region(name)
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScrollView).first
    }

    private func sendKey(_ keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
                         kind: NSEvent.EventType = .keyDown,
                         to panel: NSPanel) throws {
        guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: isRepeat,
                                           keyCode: UInt16(keyCode)) else {
            throw VerificationFailure(message: "fixture key event unavailable")
        }
        NSApp.sendEvent(event)
    }

    private func panelBitmap() throws -> NSBitmapImageRep {
        guard let view = panel?.contentView else {
            throw VerificationFailure(message: "panel unavailable for fixture capture")
        }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(ceil(bounds.width * 2)),
                                            pixelsHigh: Int(ceil(bounds.height * 2)),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw VerificationFailure(message: "unable to allocate a 2× RGBA panel capture")
        }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private func exportPanel(_ name: String, to directory: URL, bitmap: NSBitmapImageRep? = nil) throws {
        let bitmap = try bitmap ?? panelBitmap()
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw VerificationFailure(message: "unable to encode fixture PNG")
        }
        try data.write(to: directory.appending(path: "\(name).png"), options: .atomic)
    }

    private func exportWebsitePanel(_ name: String, to directory: URL) throws {
        guard let host = panel?.contentView as? NSHostingView<PopoverRoot> else {
            throw VerificationFailure(message: "SwiftUI panel unavailable for website capture")
        }
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        var root = host.rootView
        root.verification = nil
        root.rendersWebsiteImage = true
        let renderer = ImageRenderer(content: root
            .frame(width: size.width, height: size.height)
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .dark))
        let scale: CGFloat = 2
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        // Render into web sRGB even when a system app icon carries an HDR profile.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VerificationFailure(message: "unable to allocate the website render context")
        }
        context.scaleBy(x: scale, y: scale)
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        guard let image = context.makeImage() else {
            throw VerificationFailure(message: "unable to render the website panel")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = size
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw VerificationFailure(message: "unable to encode website PNG")
        }
        try data.write(to: directory.appending(path: "\(name).png"), options: .atomic)
    }

    private func snapshot(_ name: String) {
        guard let directory = verificationSnapshotDirectory else { return }
        try? exportPanel(name, to: directory)
    }

    private func openSetupFixture() async throws {
        try await dispatchStatusAction()
        try await settleMenu()
        try check(verificationRegions["Window Control Setup"] != nil && verificationRegions["Successfully setup"] == nil,
                  "untrusted setup shows permission guidance")
    }

    private var fixtureStatusGeometry: String {
        let rect = item.button.flatMap { button in
            button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let screen = item.button?.window?.screen
        return "button \(String(describing: rect)), window visible \(item.button?.window?.isVisible == true), "
            + "screen \(String(describing: screen?.frame)), visible \(String(describing: screen?.visibleFrame)), "
            + "available screens \(NSScreen.screens.map(\.frame))"
    }

    private func dispatchStatusAction(_ description: String = "status item action dispatched") async throws {
        guard let button = item.button, let action = button.action else {
            throw VerificationFailure(message: "no status item action")
        }
        let opening = panel == nil
        if opening {
            try await waitUntil("status item has no usable screen anchor (\(fixtureStatusGeometry))") { statusAnchor != nil }
        }
        try check(NSApp.sendAction(action, to: button.target, from: button), description)
        if opening && panel == nil {
            throw VerificationFailure(message: "status item did not open the panel (\(fixtureStatusGeometry))")
        }
    }

    func verifyFirstSetup(store: WorkspaceStore, output: URL?, designPreview: Bool = false,
                          handoffs: () -> [VerificationHandoff]) async throws {
        isVerifying = true
        let bytes = try Data(contentsOf: store.url)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        model.refreshSystemState()
        try check(model.windowControlStage == .required && panel == nil, "untrusted launch keeps the panel closed")
        try await openSetupFixture()
        try verifyHeader(PopoverPage.home.title)
        try check(model.state.presets.isEmpty, "setup has an empty workspace list")

        let expectedHandoff: [VerificationHandoff] = [.settings, .finder(Bundle.main.bundleURL)]
        try await click("Allow Window Control…")
        try check(handoffs() == expectedHandoff && panel == nil, "setup hands off once and closes the notch")
        try await openSetupFixture()
        if let output {
            if designPreview { try exportPanel("11-window-control-setup", to: output) }
            else { try exportWebsitePanel("setup-required", to: output) }
        }
        try await click("Allow Window Control…")
        try check(handoffs() == expectedHandoff + expectedHandoff && panel == nil,
                  "retrying the handoff does not mark setup complete")

        model.verificationAuthorized = true
        try await dispatchStatusAction()
        try await settleMenu()
        guard let original = panel else { throw VerificationFailure(message: "setup confirmation panel unavailable") }
        try check(model.windowControlStage == .confirmation && verificationRegions["Successfully setup"] != nil
                  && verificationRegions["Thanks for using AWM"] != nil && verificationRegions["Let’s start"] != nil
                  && verificationRegions["Save Current Workspace"] == nil && !ordinaryWindowIsVisible,
                  "first grant while closed shows confirmation in the notch when reopened")
        try verifyHeader("Successfully setup")
        if let output {
            if designPreview { try exportPanel("12-setup-confirmation", to: output) }
            else { try exportWebsitePanel("setup-complete", to: output) }
        }

        try sendKey(kVK_Escape, characters: "\u{1b}", to: original)
        try check(panel == nil && model.windowControlStage == .confirmation, "Escape closes the panel and preserves confirmation")
        try await dispatchStatusAction()
        try await settleMenu()
        guard let reopened = panel else { throw VerificationFailure(message: "pending confirmation panel unavailable") }
        try check(verificationRegions["Successfully setup"] != nil, "reopening restores unacknowledged confirmation")

        model.verificationAuthorized = false
        try await click("Let’s start")
        try check(model.windowControlStage == .required && verificationRegions["Window Control Setup"] != nil,
                  "a revoke before Let’s start returns to permission guidance")
        model.verificationAuthorized = true
        for _ in 0..<25 where verificationRegions["Finish Setup row"] == nil {
            try await Task.sleep(for: .milliseconds(65))
        }
        try check(panel === reopened && verificationRegions["Successfully setup"] != nil,
                  "a grant while the notch is open shows confirmation in that panel")
        try sendKey(kVK_Return, characters: "\r", to: reopened)
        try await settleMenu()
        try check(panel === reopened && model.windowControlStage == .ready && verificationRegions["Workspaces"] != nil
                  && verificationRegions["Successfully setup"] == nil && verificationRegions["Save Current Workspace"] != nil
                  && presentedPage?.surface == .page(.home) && presentedPage?.opacity == 1 && reopened.isKeyWindow,
                  "Return acknowledges confirmation and goes directly to Workspaces")
        let finalPermissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        try check(try Data(contentsOf: store.url) == bytes && permissions == NSNumber(value: 0o600)
                  && finalPermissions == permissions, "onboarding preserves workspace bytes and owner-only mode")
    }

    func captureReady(focus: UUID, output: URL, designPreview: Bool = false) async throws {
        isVerifying = true
        try await dispatchStatusAction()
        try await settleMenu()
        let names = ["Focus", "Vibing", "Planning"]
        try check(model.windowControlStage == .ready && model.state.lastActive == focus
                  && model.state.presets.map(\.name) == names
                  && names.allSatisfy { verificationRegions["Restore: \($0)"] != nil }
                  && verificationRegions["Save Current Workspace"] != nil
                  && verificationRegions["Update Active Workspace"] != nil,
                  "ready screenshot shows only Focus, Vibing, and Planning, with Focus active")
        guard designPreview else {
            try exportWebsitePanel("app-ready", to: output)
            return
        }
        let workspaces = try panelBitmap()
        let restore = try region("Restore: Focus")
        let manage = try region("Manage: Focus")
        let selected = try panelColor(at: CGPoint(x: restore.midX, y: restore.midY), bitmap: workspaces)
        for x in [restore.minX + 2, manage.maxX - 2] {
            let top = try panelColor(at: CGPoint(x: x, y: restore.minY + 2), bitmap: workspaces)
            let bottom = try panelColor(at: CGPoint(x: x, y: restore.maxY - 2), bitmap: workspaces)
            try check(top != selected && bottom == selected,
                      "active row's fill is clipped only at the card's top corners")
        }
        try exportPanel("01-workspaces", to: output, bitmap: workspaces)
        try await captureCardRow("Restore: Vibing", named: "19-middle-workspace-restore-hover",
                                 edges: .leading, output: output)
        try await captureCardRow("Manage: Vibing", named: "20-middle-workspace-manage-hover",
                                 edges: .trailing, output: output)
        try await click("Save Current Workspace")
        try check(presentedPage?.surface == .page(.capture) && verificationRegions["Workspace name"] != nil,
                  "save action opens the draft in the live panel")
        guard let editor = panel?.firstResponder as? NSTextView else {
            throw VerificationFailure(message: "preview capture name field did not take focus")
        }
        editor.insertText("Planning Review", replacementRange: editor.selectedRange())
        try await settleMenu()
        try exportPanel("02-save-workspace", to: output)
        try await click("Cancel")
        try check(presentedPage?.surface == .page(.home) && model.state.presets.count == names.count,
                  "canceling the draft returns home and keeps the sample workspaces")
        try await click("Manage: Focus")
        try check(presentedPage?.surface == .page(.preset(focus)), "ellipsis opens workspace management")
        try exportPanel("03-manage-workspace", to: output)
        try await click("Back")
        try await click("Navigation: Settings")
        try check(presentedPage?.surface == .page(.settings), "footer opens Settings")
        try exportPanel("04-settings", to: output)
        try await captureCardRow("Navigation: Keyboard Shortcuts", named: "13-first-row-hover",
                                 roundedTop: true, output: output)
        try await captureCardRow("Navigation: Window Sizing", named: "14-middle-row-hover", output: output)
        try await captureCardRow("Navigation: General Preferences", named: "15-last-row-hover",
                                 roundedBottom: true, output: output)
        try await captureRowFocus("Navigation: Window Sizing", to: output)
        try await click("Navigation: Display & Workspace Behavior")
        try check(presentedPage?.surface == .page(.displays), "settings row opens display and workspace behavior")
        try exportPanel("05-display-preferences", to: output)
        try await click("Back")
        try await click("Navigation: Keyboard Shortcuts")
        try exportPanel("06-keyboard-shortcuts", to: output)
        try await click("Back")
        try await click("Navigation: Window Sizing")
        try exportPanel("07-window-sizing", to: output)
        try await click("Back")
        try await click("Navigation: General Preferences")
        try exportPanel("08-general-preferences", to: output)
        try await click("Back")
        try await click("Back")
        try await click("Update Active Workspace")
        try exportPanel("09-update-workspace", to: output)
        try await click("Back")
        try await click("Navigation: About")
        try exportPanel("10-about", to: output)
        try await click("Back")
        for preset in model.state.presets where preset.id != focus { model.delete(preset.id) }
        try await settleMenu()
        try check(model.state.presets.map(\.id) == [focus], "singleton preview has one active workspace")
        try await captureCardRow("Restore: Focus", named: "17-singleton-restore-hover",
                                 roundedTop: true, roundedBottom: true, edges: .leading, output: output)
        try await captureCardRow("Manage: Focus", named: "18-singleton-manage-hover",
                                 roundedTop: true, roundedBottom: true, edges: .trailing, output: output)
    }

    private func captureCardRow(_ row: String, named name: String, roundedTop: Bool = false,
                                roundedBottom: Bool = false, edges: Edge.Set = .horizontal,
                                output: URL) async throws {
        let frame = try region(row)
        let baseline = try panelBitmap()
        verificationHover.point = CGPoint(x: frame.midX, y: frame.midY)
        defer { verificationHover.point = nil }
        try await settleMenu()
        let hovered = try panelBitmap()
        func checkSample(_ point: CGPoint, highlighted: Bool) throws {
            let change = try colorChange(at: point, from: baseline, to: hovered)
            try check(highlighted ? change > 0.04 : change < 0.01,
                      "\(row) \(highlighted ? "fills to" : "clips") card edge at \(point), color change \(change)")
        }
        for x in [edges.contains(.leading) ? frame.minX + 2 : nil,
                  edges.contains(.trailing) ? frame.maxX - 2 : nil].compactMap({ $0 }) {
            try checkSample(CGPoint(x: x, y: frame.midY), highlighted: true)
            try checkSample(CGPoint(x: x, y: frame.minY + 2), highlighted: !roundedTop)
            try checkSample(CGPoint(x: x, y: frame.maxY - 2), highlighted: !roundedBottom)
        }
        try exportPanel(name, to: output, bitmap: hovered)
        verificationHover.point = nil
        try await settleMenu()
    }

    private func captureRowFocus(_ row: String, to output: URL) async throws {
        let frame = try region(row)
        let baseline = try panelBitmap()
        verificationHover.focusPoint = CGPoint(x: frame.midX, y: frame.midY)
        defer { verificationHover.focusPoint = nil }
        try await settleMenu()
        let focused = try panelBitmap()
        for point in [CGPoint(x: frame.midX, y: frame.minY + 0.75),
                      CGPoint(x: frame.minX + 1.5, y: frame.midY)] {
            let change = try colorChange(at: point, from: baseline, to: focused)
            try check(change > 0.3, "\(row) shows a high-visibility focus border at \(point)")
        }
        try exportPanel("16-middle-row-focus", to: output, bitmap: focused)
        verificationHover.focusPoint = nil
        try await settleMenu()
    }

    private func checkAnimation(from previous: CGFloat, to current: CGFloat) throws {
        let widths = verificationResizeFrames.map(\.width)
        if reduceMotion() {
            // AppKit can round a half-point window origin differently on different displays.
            let matchesRequests = verificationResizeFrames.count == verificationFitRequests.count
                && zip(verificationResizeFrames, verificationFitRequests).allSatisfy { actual, requested in
                    abs(actual.minX - requested.minX) <= 1 && abs(actual.maxY - requested.maxY) <= 1
                        && abs(actual.width - requested.width) <= 1 && abs(actual.height - requested.height) <= 1
                }
            try check(widths.last == current && matchesRequests,
                      "reduced motion applies each measured size directly without interpolation")
        } else {
            try check(widths.contains { $0 > min(previous, current) && $0 < max(previous, current) }
                      && widths.last == current, "panel width animates through intermediate frames")
        }
        let top = min(anchor.minY, visibleFrame.maxY)
        let anchored = verificationResizeFrames.allSatisfy { frame in
            let left = PanelGeometry.leadingEdge(anchorX: anchor.midX, visibleFrame: visibleFrame, width: frame.width)
            return abs(frame.minX - left) <= 1 && abs(frame.maxY - top) <= 1
        }
        try check(anchored, "resizing stays under the menu bar icon through every frame")
    }

    private struct NavigationFrame {
        let name: String
        let time: TimeInterval
        let page: MenuPagePresentation
        let header: CGRect
        let window: CGRect
        let text: CGRect
        let bitmap: NSBitmapImageRep

        func textLuminance() -> Double {
            Self.peakLuminance(in: text, bitmap: bitmap)
        }

        static func peakLuminance(in rect: CGRect, bitmap: NSBitmapImageRep) -> Double {
            let scale = Double(bitmap.pixelsWide) / bitmap.size.width
            let left = max(0, Int(rect.minX * scale))
            let right = min(bitmap.pixelsWide, Int(ceil(rect.maxX * scale)))
            let top = max(0, Int(rect.minY * scale))
            let bottom = min(bitmap.pixelsHigh, Int(ceil(rect.maxY * scale)))
            guard left < right, top < bottom else { return 0 }
            var brightest = 0.0
            for y in top..<bottom {
                for x in left..<right {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent].map {
                        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
                    }
                    let luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
                    brightest = max(brightest, luminance)
                }
            }
            return brightest
        }
    }

    private func verifyHeader(_ title: String, hasBack: Bool = false, hasWorkspaceActions: Bool = false) throws {
        let frame = try navigationFrame("header", text: "AWM header mark")
        let mark = frame.text
        let titleRect = try region(title)
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]).width
        let back = verificationRegions["Back row"]
        try check(frame.header.contains(mark) && abs(mark.width - 26) < 0.25 && abs(mark.height - 13) < 0.25
                  && frame.header.contains(titleRect) && mark.maxX < titleRect.minX
                  && titleRect.width >= titleWidth - 2,
                  "\(title) header fits the logo and its full title (header \(frame.header), mark \(mark), "
                  + "title \(titleRect), intrinsic width \(titleWidth))")
        if hasBack, let back {
            try check(frame.header.contains(back) && mark.maxX < back.minX && back.maxX < titleRect.minX,
                      "\(title) keeps Back between the logo and title")
        } else {
            try check(!hasBack && back == nil, "\(title) has the expected Back control state")
        }
        if hasWorkspaceActions {
            let count = try region("Saved workspace count")
            let restore = try region("Restore Active Workspace")
            try check(frame.header.contains(count) && frame.header.contains(restore)
                      && titleRect.maxX < count.minX && count.maxX < restore.minX,
                      "\(title) fits the saved count and Restore action (header \(frame.header), count \(count), Restore \(restore))")
        }
        let background = CGRect(x: mark.minX, y: frame.header.minY + 3, width: mark.width, height: 4)
        let dark = NavigationFrame.peakLuminance(in: background, bitmap: frame.bitmap)
        let bright = frame.textLuminance()
        let contrast = (bright + 0.05) / (dark + 0.05)
        try check(bright >= 0.85 && contrast >= 4.5, "\(title) renders a white logo with at least 4.5:1 contrast")
    }

    private func navigationFrame(_ name: String, text: String) throws -> NavigationFrame {
        guard let page = presentedPage, let panel else {
            throw VerificationFailure(message: "no presented destination for (name)")
        }
        let time = ProcessInfo.processInfo.systemUptime
        return NavigationFrame(name: name, time: time, page: page, header: try region("Page header"),
                               window: panel.frame, text: try region(text), bitmap: try panelBitmap())
    }

    private func verifyNavigation(_ name: String, click row: String, returnVia returnRow: String,
                                  from source: PopoverPage, to destination: PopoverPage,
                                  direction: PageEntrance, sourceText: String, text: String)
        async throws {
        let before = try navigationFrame("before", text: sourceText)
        verificationPages = Array(verificationPages.suffix(1))
        let began = try await dispatchClick(row).time
        try await settleMenu()
        let history = verificationPages.filter { $0.time >= began }
        let settled = try navigationFrame("settled", text: text)

        // AppKit's synchronous bitmap cache can hold the main run loop across several frames.
        // Capture one instant per identical navigation and use the first run for uninterrupted timing.
        var frames: [(frame: NavigationFrame, elapsed: TimeInterval)] = [(before, before.time - began)]
        for (phase, elapsed) in [("early", 0.055), ("middle", 0.095), ("late", 0.215)] {
            try await click(returnRow)
            let trialStart = try await dispatchClick(row).time
            let remaining = trialStart + elapsed - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try await waitUntil("no \(destination.title) page appeared for \(name)") {
                presentedPage?.surface == .page(destination) && verificationRegions[text] != nil
            }
            let frame = try navigationFrame(phase, text: text)
            frames.append((frame, frame.time - trialStart))
            try await settleMenu()
        }
        frames.append((settled, settled.time - began))

        let endpoint = settled.page
        let arriving = frames.dropFirst().map(\.frame)
        let destinations = history.flatMap(\.presentations).filter { $0.surface == .page(destination) }
        let pixels = arriving.map { $0.textLuminance() }
        if let path = ProcessInfo.processInfo.environment["AWM_VERIFY_SNAPSHOT_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            for (frame, _) in frames {
                try exportPanel("\(name)-\(frame.name)", to: directory, bitmap: frame.bitmap)
            }
        }
        for (frame, elapsed) in frames {
            print(String(format: "FRAME %@ %@ %.0fms page=%@ x=%+.2f alpha=%.3f text-x=%.2f text-light=%.3f width=%.1f",
                         name, frame.name, elapsed * 1_000, String(describing: frame.page.surface),
                         frame.page.offset, frame.page.opacity, frame.text.minX, frame.textLuminance(), frame.window.width))
        }
        try check(before.page.surface == .page(source) && before.page.offset == 0 && before.page.opacity == 1
                  && endpoint.surface == .page(destination) && endpoint.offset == 0 && endpoint.opacity == 1
                  && !destinations.isEmpty && history.allSatisfy { $0.presentations.count <= 1 },
                  "\(name) commits one destination and settles at rest")
        let fixedHeader = frames.map(\.frame).allSatisfy {
            abs($0.header.minX - before.header.minX) < 0.05 && abs($0.header.minY - before.header.minY) < 0.05
                && abs($0.header.height - before.header.height) < 0.05 && abs($0.window.maxY - before.window.maxY) <= 1
                && abs($0.window.minX - PanelGeometry.leadingEdge(anchorX: anchor.midX, visibleFrame: visibleFrame,
                                                                 width: $0.window.width)) <= 1
        }
        try check(fixedHeader && panel?.isKeyWindow == true, "\(name) keeps the header and notch anchored and the panel key")
        let finalBrightness = settled.textLuminance()
        try check(finalBrightness >= 0.35 && arriving.allSatisfy {
            abs($0.text.minX - settled.text.minX - $0.page.offset) <= 1
        }, "\(name) captures destination text at the measured position")
        if reduceMotion() {
            try check(destinations.allSatisfy { $0.offset == 0 && $0.opacity == 1 }
                      && pixels.allSatisfy { abs($0 - finalBrightness) < 0.10 },
                      "\(name) appears fully opaque without an intermediate frame in Reduce Motion")
        } else {
            let sign: CGFloat = direction == .forward ? 1 : -1
            let offsets = arriving.map { sign * $0.page.offset }
            let alpha = arriving.map(\.page.opacity)
            let middleTime = frames[2].elapsed
            let settledTime = history.first {
                $0.presentations.contains { $0.surface == endpoint.surface && $0.offset == 0 && $0.opacity == 1 }
            }?.time ?? .infinity
            let visibleMiddle = history.contains {
                (0.070...0.110).contains($0.time - began) && $0.presentations.contains {
                    $0.surface == endpoint.surface && sign * $0.offset >= 8 && $0.opacity > 0.25
                }
            }
            try check(offsets[0] > offsets[1] + 1 && offsets[1] > offsets[2] + 1 && offsets[2] > 0
                      && alpha[0] < alpha[1] && alpha[1] < alpha[2] && alpha[2] < 1
                      && (0.070...0.125).contains(middleTime) && offsets[1] >= 8 && visibleMiddle,
                      "\(name) moves \(direction == .forward ? "in from the right" : "in from the left") across distinct visible frames")
            try check((0.275...0.410).contains(settledTime - began),
                      "\(name) reaches its fully drawn position in \(Int((settledTime - began) * 1_000)) ms")
            try check(pixels[0] + 0.08 < finalBrightness && pixels[1] + 0.05 < finalBrightness
                      && pixels[2] > pixels[0] + 0.10,
                      "\(name) changes the actual rendered text contrast through the fade")
        }
    }

    private func motionValues(_ motion: MenuMotion, at point: CGPoint = .zero) -> [Double] {
        verificationMotion.compactMap { samples in
            samples.first { $0.motion == motion && $0.frame.contains(point) }?.opacity
        }
    }

    private func checkFade(_ values: [Double], from start: Double, to end: Double, _ label: String) throws {
        let lower = min(start, end) + 0.001
        let upper = max(start, end) - 0.001
        let hasIntermediate = values.contains { $0 > lower && $0 < upper }
        let last = values.last.map { abs($0 - end) < 0.001 } ?? false
        try check(last && hasIntermediate != reduceMotion(),
                  "\(label) \(reduceMotion() ? "settles immediately" : "fades through intermediate opacity")")
    }

    private func panelColor(at point: CGPoint, bitmap: NSBitmapImageRep? = nil) throws -> NSColor {
        let bitmap = try bitmap ?? panelBitmap()
        guard let color = bitmap.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.usingColorSpace(.sRGB) else {
            throw VerificationFailure(message: "fixture row color unavailable")
        }
        return color
    }

    private func colorChange(at point: CGPoint, from baseline: NSBitmapImageRep, to current: NSBitmapImageRep) throws -> CGFloat {
        let before = try panelColor(at: point, bitmap: baseline)
        let after = try panelColor(at: point, bitmap: current)
        return colorDistance(before, after)
    }

    private func colorDistance(_ before: NSColor, _ after: NSColor) -> CGFloat {
        return max(abs(after.redComponent - before.redComponent),
                   abs(after.greenComponent - before.greenComponent),
                   abs(after.blueComponent - before.blueComponent))
    }

    private func verifyCardDividers(_ rows: [String], visible: [Bool], _ description: String) throws {
        let frames = try rows.map(region)
        let image = try panelBitmap()
        let gaps = zip(frames, frames.dropFirst())
        try check(visible.count == frames.count - 1 && gaps.allSatisfy {
            abs($1.minY - $0.maxY - 1) < 0.01 && abs($1.minX - $0.minX) < 0.01
        }, "\(description) keeps the one-point separator slots")
        for ((upper, _), expected) in zip(gaps, visible) {
            let y = upper.maxY + 0.25
            let fill = try panelColor(at: CGPoint(x: upper.minX + 7, y: y), bitmap: image)
            let edge = try panelColor(at: CGPoint(x: upper.minX + 0.25, y: y), bitmap: image)
            let line = try panelColor(at: CGPoint(x: upper.minX + 20, y: y), bitmap: image)
            let difference = colorDistance(fill, line)
            try check(colorDistance(fill, edge) > 0.06, "\(description) retains the outer card border")
            try check(expected ? difference > 0.06 : difference < 0.01,
                      "\(description) \(expected ? "shows" : "blends") the separator at \(y) (color difference \(difference))")
        }
    }

    private func waitForRowHighlight() async throws {
        try await Task.sleep(for: .milliseconds(reduceMotion() ? 32 : 165))
    }

    private func verifyWorkspaceDividers(_ longName: String, disabled: Bool = false) async throws {
        let rows = ["Restore: Focus", "Restore: Vibing", "Restore: \(longName)"]
        try verifyCardDividers(rows, visible: [false, true], "active workspace at rest")
        defer { verificationHover.point = nil }
        for target in ["Restore: Vibing", "Manage: Vibing"] {
            let frame = try region(target)
            verificationHover.point = CGPoint(x: frame.midX, y: frame.midY)
            try await waitForRowHighlight()
            try verifyCardDividers(rows, visible: [false, disabled], "\(target) \(disabled ? "disabled" : "hovered")")
        }
        verificationHover.point = nil
        try await waitForRowHighlight()
        try verifyCardDividers(rows, visible: [false, true], "workspace pointer exit")
    }

    private func verifyNavigationDividers() async throws {
        let rows = ["Keyboard Shortcuts", "Window Sizing", "Display & Workspace Behavior", "General Preferences"]
            .map { "Navigation: \($0)" }
        let frames = try rows.map(region)
        let outerFrame = panel?.frame
        let points = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
        defer {
            verificationHover.point = nil
            verificationHover.focusPoint = nil
        }
        try verifyCardDividers(rows, visible: [true, true, true], "settings at rest")
        for (index, visible) in [(0, [false, true, true]), (1, [false, false, true]), (3, [true, true, false])] {
            verificationHover.point = points[index]
            try await waitForRowHighlight()
            try verifyCardDividers(rows, visible: visible, "\(rows[index]) hover")
        }
        verificationHover.point = points[0]
        try await Task.sleep(for: .milliseconds(40))
        verificationHover.point = points[3]
        try await waitForRowHighlight()
        try verifyCardDividers(rows, visible: [true, true, false], "rapid settings hover")
        verificationHover.point = nil
        verificationHover.focusPoint = points[1]
        try await waitForRowHighlight()
        try verifyCardDividers(rows, visible: [false, false, true], "focused settings row")
        verificationHover.focusPoint = nil
        try await waitForRowHighlight()
        try verifyCardDividers(rows, visible: [true, true, true], "after pointer and focus leave settings")
        try check(try rows.map(region) == frames && panel?.frame == outerFrame,
                  "divider highlights never shift card rows or resize the panel")
        _ = try await dispatchClick(rows[0], events: [.leftMouseDown])
        try await waitForRowHighlight()
        try verifyCardDividers(rows, visible: [false, true, true], "pressed settings row")
        _ = try await dispatchClick(rows[0], events: [.leftMouseUp])
        try await settleMenu()
        try check(presentedPage?.surface == .page(.shortcuts), "releasing the pressed row opens Keyboard Shortcuts")
        try await click("Back")
    }

    private func verifyHover(on row: String, disabled: Bool = false) async throws {
        let frame = try region(row)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let swatch = CGPoint(x: frame.minX + 6, y: frame.midY)
        let baseline = try panelColor(at: swatch)
        verificationMotion = Array(verificationMotion.suffix(1))
        verificationHover.point = point
        try await Task.sleep(for: .milliseconds(165))
        let entering = motionValues(.hover, at: point)
        if disabled {
            try check(!entering.isEmpty && entering.allSatisfy { $0 == 0 }, "disabled row has no hover highlight")
        } else {
            try checkFade(entering, from: 0, to: MenuPalette.hoverOpacity, "\(row) hover-in")
            let highlighted = try panelColor(at: swatch)
            try check(highlighted.redComponent > baseline.redComponent
                      && highlighted.greenComponent > baseline.greenComponent
                      && highlighted.blueComponent > baseline.blueComponent,
                      "\(row) hover lightens the rendered surface")
            snapshot(row == "Restore: Focus" ? "hover-selected" : "hover-normal")
        }
        verificationMotion = Array(verificationMotion.suffix(1))
        verificationHover.point = nil
        try await Task.sleep(for: .milliseconds(165))
        if !disabled {
            try checkFade(motionValues(.hover, at: point), from: MenuPalette.hoverOpacity, to: 0, "\(row) hover-out")
        }
    }

    private func verification(for panel: StatusPanel) -> PopoverVerification {
        verificationRegions = [:]
        verificationMotion = []
        verificationPages = []
        return PopoverVerification(
            record: { [weak self, weak panel] regions in
                guard let self, let panel, self.panel === panel else { return }
                self.verificationRegions = regions
            },
            recordMotion: { [weak self, weak panel] samples in
                guard let self, let panel, self.panel === panel else { return }
                self.verificationMotion.append(samples)
            },
            recordPage: { [weak self, weak panel] pages in
                guard let self, let panel, self.panel === panel else { return }
                self.verificationPages.append(TimedPage(time: ProcessInfo.processInfo.systemUptime, presentations: pages))
            },
            hover: verificationHover,
            openURL: OpenURLAction { [weak self] url in
                self?.verificationURLs.append(url)
                return .handled
            }
        )
    }

    private func verifyWorkspaceMoves(store: WorkspaceStore, focus: UUID, longName: String) async throws {
        func checkOrder(_ names: [String]) throws {
            let rows = try names.map { try region("Restore: \($0)") }
            try check(zip(rows, rows.dropFirst()).allSatisfy { $0.maxY <= $1.minY },
                      "Home displays the saved workspace order")
            try check(verificationRegions["Active workspace: Focus"] != nil,
                      "the active marker stays with the moved workspace")
        }

        let original = try store.load().state
        let originalBytes = try Data(contentsOf: store.url)
        try await click("Manage: Focus", at: .leading)
        try check(presentedPage?.surface == .page(.preset(focus)) && verificationRegions["Position 1 of 3"] != nil,
                  "Manage Workspace reports the original position")
        try await click("Move Up")
        try check(try Data(contentsOf: store.url) == originalBytes, "moving above the first row leaves storage alone")
        try await click("Move Down")
        try check(presentedPage?.surface == .page(.preset(focus)) && verificationRegions["Position 2 of 3"] != nil,
                  "Move Down updates the position on the same Manage Workspace page")
        var expected = original
        expected.presets.swapAt(0, 1)
        try check(try store.load().state == expected, "Move Down persists the workspace order")

        try await click("Back")
        try checkOrder(["Vibing", "Focus", longName])
        try verifyCardDividers(["Restore: Vibing", "Restore: Focus", "Restore: \(longName)"],
                               visible: [false, false], "active workspace moved to the middle")
        try await dispatchStatusAction("dismiss the reordered menu")
        try await dispatchStatusAction("reopen the reordered menu")
        try await settleMenu()
        try checkOrder(["Vibing", "Focus", longName])

        try await click("Manage: Focus", at: .leading)
        try await click("Move Up")
        try check(verificationRegions["Position 1 of 3"] != nil && (try store.load().state) == original,
                  "Move Up restores the original position and saved order")
        try await click("Back")
        try checkOrder(["Focus", "Vibing", longName])
        try verifyCardDividers(["Restore: Focus", "Restore: Vibing", "Restore: \(longName)"],
                               visible: [false, true], "active workspace moved back to the first row")
    }

    func verify(store: WorkspaceStore, focus: UUID, longName: String, snapshots: URL?,
                handoffs: () -> [VerificationHandoff]) async throws {
        if let snapshots {
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        }
        verificationSnapshotDirectory = snapshots
        isVerifying = true
        var restoreRequests: [UUID] = []
        model.verificationRestore = { restoreRequests.append($0) }
        defer { model.verificationRestore = nil }
        try check(NSApp.activationPolicy() == .accessory, "accessory app")
        let displays = model.system.displays()
        try check(displays.primary != nil && displays.screens.allSatisfy { $0.frame.contains($0.usable) },
                  "reads live display and usable area")
        let ordinaryWindows = NSApp.windows.filter { $0.isVisible && ($0.isMainWindow || $0.styleMask.contains(.titled)) }
        try check(ordinaryWindows.isEmpty, "no regular window at launch")
        guard let button = item.button else { throw VerificationFailure(message: "no status item button") }
        let appName = "Another Window Management"
        try check(button.accessibilityLabel() == appName && button.toolTip == appName,
                  "status item uses the current accessible name and tooltip")
        try check(button.image?.isTemplate == true, "template icon")
        try check(button.image?.size == NSSize(width: 28, height: 12), "approved menu icon size")
        try check(button.title.isEmpty && button.imagePosition == .imageOnly, "menu bar shows only the icon")

        try await dispatchStatusAction()
        if reduceMotion() {
            try check(panel?.alphaValue == 1, "reduced-motion panel appears immediately")
        }
        guard let original = panel else { throw VerificationFailure(message: "status panel unavailable") }
        try await waitUntil("Workspaces did not fit its long fixture name") { original.frame.width > PanelGeometry.initialSize.width }
        try await settleMenu()
        try check(original.isVisible && original.contentView is NSHostingView<PopoverRoot>,
                  "status item opens the SwiftUI panel")
        try check(original.isKeyWindow, "panel accepts keyboard focus")
        try check(presentedPage?.surface == .page(.home) && presentedPage?.offset == 0 && presentedPage?.opacity == 1,
                  "the initial Workspaces body opens at rest")
        try verifyHeader(PopoverPage.home.title, hasWorkspaceActions: true)
        let top = min(anchor.minY, visibleFrame.maxY)
        try check(abs(original.frame.maxY - top) <= 1,
                  "panel stays below the menu bar (\(original.frame.maxY), expected \(top))")
        let wide = original.frame.width
        let homeRows = try ["Restore: Focus", "Restore: Vibing", "Manage: Focus"].map(region)
        try check(original.firstResponder === original, "opening the menu leaves focus on the panel")
        try sendKey(kVK_Return, characters: "\r", to: original)
        try sendKey(kVK_Space, characters: " ", to: original)
        try sendKey(kVK_Space, characters: " ", kind: .keyUp, to: original)
        try await settleMenu()
        try check(restoreRequests.isEmpty, "Return and Space after opening leave workspaces in place")
        let header = try region("Page header")
        let headerGap = homeRows[0].minY - header.maxY
        try check(abs(header.height - MenuMetrics.headerHeight) < 0.25
                  && homeRows.allSatisfy { abs($0.height - MenuMetrics.workspaceRowHeight) < 0.25 }
                  && abs(headerGap - MenuMetrics.headerBottomInset) < 0.25,
                  "heading and workspace rows match the menu’s spacing (gap \(headerGap), rows \(homeRows.map(\.height)))")
        let longTitle = try region("Text: \(longName)")
        let longTitleWidth = (longName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        try check(wide > PanelGeometry.initialSize.width && longTitle.height <= 18
                  && longTitle.width >= longTitleWidth - 2, "home fits the long workspace name on one line")
        snapshot("notch")
        try await verifyWorkspaceDividers(longName)
        try await verifyHover(on: "Restore: Vibing")
        try await verifyHover(on: "Restore: Focus")
        verificationMotion = []
        let normalPoint = CGPoint(x: homeRows[1].midX, y: homeRows[1].midY)
        let activePoint = CGPoint(x: homeRows[0].midX, y: homeRows[0].midY)
        verificationHover.point = normalPoint
        try await Task.sleep(for: .milliseconds(40))
        verificationHover.point = activePoint
        try await Task.sleep(for: .milliseconds(165))
        try check(motionValues(.hover, at: normalPoint).last == 0
                  && motionValues(.hover, at: activePoint).last == MenuPalette.hoverOpacity,
                  "rapid hover leaves only the latest row highlighted")
        verificationHover.point = nil

        verificationResizeFrames = []
        verificationFitRequests = []
        try await verifyNavigation("home-manage", click: "Manage: Focus", returnVia: "Back", from: .home, to: .preset(focus),
                                   direction: .forward, sourceText: "Text: Vibing", text: "Text: Focus")
        let compact = original.frame.width
        try check(compact < wide && panel === original && original.isKeyWindow, "short workspace details shrink the same panel")
        try checkAnimation(from: wide, to: compact)
        try verifyHeader(PopoverPage.preset(focus).title, hasBack: true)
        snapshot("manage-workspace")
        try await click("Change Icon…")
        try await click("Icon: \(WorkspaceIcon.star.title)")
        snapshot("workspace-icons")
        try await click("Cancel")
        try check(model.state.preset(focus)?.icon == .layout, "cancel keeps the existing workspace icon")
        try await click("Change Icon…")
        try await click("Icon: \(WorkspaceIcon.star.title)")
        try await click("Apply Icon")
        let saved = try store.load().state
        try check(saved.preset(focus)?.icon == .star && saved.lastActive == focus,
                  "icon saves and active workspace stays")

        try await click("Shortcut: Focus")
        try check(model.recording == .preset(focus), "workspace shortcut enters recording")
        snapshot("workspace-shortcut")
        try sendKey(kVK_Escape, characters: "\u{1b}", to: original)
        try check(model.recording == nil && panel === original, "Escape cancels shortcut recording")
        try await click("Update from Current Layout")
        try verifyHeader(PopoverPage.capture.title, hasBack: true)
        snapshot("workspace-capture")
        try await click("Back")
        try check(presentedPage?.surface == .page(.preset(focus)), "canceling a capture returns to its actual source")
        try await verifyNavigation("manage-home", click: "Back", returnVia: "Manage: Focus", from: .preset(focus), to: .home,
                                   direction: .backward, sourceText: "Text: Focus", text: "Text: Vibing")
        try check(original.frame.width == wide, "returning home restores the width of its content")

        try await click("Settings")
        try verifyHeader(PopoverPage.settings.title, hasBack: true)
        snapshot("settings")
        try await verifyNavigationDividers()
        let settingsWidth = original.frame.width
        verificationResizeFrames = []
        verificationFitRequests = []
        try await click("Display & Workspace Behavior")
        try verifyHeader(PopoverPage.displays.title, hasBack: true)
        let displayWidth = original.frame.width
        try check(displayWidth > settingsWidth, "display preferences expand to fit their labels and switches")
        try checkAnimation(from: settingsWidth, to: displayWidth)
        let revealLabel = "Show apps and windows during restore"
        let revealWidth = (revealLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let switchRow = try region("Switch: \(revealLabel)")
        let helperRow = try region("Switch group: Restore a workspace when displays change")
        try check(switchRow.height >= MenuMetrics.workspaceRowHeight && helperRow.height >= switchRow.height,
                  "switch rows keep room for their visible description")
        snapshot("display-workspace-behavior")
        guard let longID = model.state.presets.first(where: { $0.name == longName })?.id else {
            throw VerificationFailure(message: "long workspace fixture unavailable")
        }
        try check(model.rename(longID, to: "Planning"), "fixture shortens its display association label")
        try await settleMenu()
        let revealText = try region("Text: \(revealLabel)")
        try check(original.frame.width < displayWidth && revealText.height <= 18 && revealText.width >= revealWidth - 2,
                  "show apps and windows during restore fits on one line with short workspace names")
        snapshot("display-short-workspace-names")
        try check(model.rename(longID, to: longName), "fixture restores its long display association label")
        try await settleMenu()

        guard let fixtureLayout = model.verificationCapture?.displays,
              let vibingID = model.state.presets.first(where: { $0.name == "Vibing" })?.id else {
            throw VerificationFailure(message: "display association fixture unavailable")
        }
        let automaticRestore = "Switch: Restore a workspace when displays change"
        try await click("Switch: Focus", at: .trailing)
        let association = try store.load().state
        try check(association.preset(focus)?.followsDisplays == true && association.automaticPreset(for: fixtureLayout) == nil,
                  "a saved association waits for automatic restore to be enabled")
        try await click(automaticRestore, at: .trailing)
        try check(try store.load().state.automaticPreset(for: fixtureLayout)?.id == focus,
                  "automatic restore uses the associated workspace")
        try await click("Switch: Vibing", at: .trailing)
        let transferred = try store.load().state
        try check(transferred.preset(focus)?.followsDisplays == false
                  && transferred.automaticPreset(for: fixtureLayout)?.id == vibingID,
                  "associating another workspace transfers restore eligibility")
        try await click("Switch: Vibing", at: .trailing)
        try check(try store.load().state.automaticPreset(for: fixtureLayout) == nil,
                  "turning off the association leaves no automatic workspace")

        try await click("Back")
        try await click("Window Sizing")
        try verifyHeader(PopoverPage.sizing.title, hasBack: true)
        try await verifySizing(store: store, in: original)
        try await click("Back")
        try await verifyNavigation("settings-general", click: "General Preferences", returnVia: "Back", from: .settings, to: .general,
                                   direction: .forward, sourceText: "Text: Keyboard Shortcuts", text: "Text: Launch at login")
        try verifyHeader(PopoverPage.general.title, hasBack: true)
        let before = model.state.preferences.restoreOnLaunch
        try await click("Switch: Restore last active workspace on launch", at: .trailing)
        let reopened = try store.load().state
        try check(reopened.preferences.restoreOnLaunch != before, "native switch persists the changed preference")
        snapshot("general-preferences")
        try await verifyNavigation("general-settings", click: "Back", returnVia: "General Preferences",
                                   from: .general, to: .settings, direction: .backward,
                                   sourceText: "Text: Launch at login", text: "Text: Keyboard Shortcuts")
        try await click("Keyboard Shortcuts")
        try verifyHeader(PopoverPage.shortcuts.title, hasBack: true)
        let leftAction = ArrangementAction.left.label
        let rightAction = ArrangementAction.right.label
        let leftTitle = try region(leftAction)
        let rightTitle = try region(rightAction)
        let recordRow = try region("Shortcut: \(leftAction)")
        let changeRow = try region("Shortcut: \(rightAction)")
        let disableRow = try region("Disable: \(rightAction)")
        try check(recordRow.height == 38 && changeRow.height == 38 && disableRow.height == 38,
                  "shortcut action rows match the 38-point menu rows")
        try check(abs(recordRow.minX + 10 - leftTitle.minX - 22) < 0.5
                  && recordRow.maxX == disableRow.maxX
                  && rightTitle.minY - recordRow.maxY >= 16,
                  "shortcut controls are indented and their groups are separated")
        snapshot("keyboard-shortcuts")
        let lastShortcut = "Shortcut: \(longName)"
        let lastShortcutBeforeScroll = try region(lastShortcut)
        let lastShortcutAfterScroll = try await visibleRegion(lastShortcut, in: original)
        try check(original.frame.height <= PanelGeometry.maximumHeight
                  && lastShortcutAfterScroll.midY < original.frame.height
                  && lastShortcutAfterScroll.minY < lastShortcutBeforeScroll.minY,
                  "the capped panel scrolls to the last shortcut")
        try await click("Shortcut: \(leftAction)")
        try check(model.recording == .arrange(.left), "keyboard settings starts recording on the unassigned action")
        snapshot("keyboard-recording")
        try sendKey(kVK_F19, characters: "\u{F716}", modifiers: [.control, .option, .shift], isRepeat: true, to: original)
        try sendKey(kVK_ANSI_A, characters: "a", to: original)
        try check(model.recording == .arrange(.left) && model.shortcut(for: .arrange(.left)) == nil,
                  "repeat events and unmodified keys leave recording active")
        try sendKey(kVK_F19, characters: "\u{F716}", modifiers: [.control, .option, .shift], to: original)
        try await waitUntil("keyboard shortcut recording did not finish") {
            model.recording == nil && verificationRegions["Shortcut: \(leftAction)"] != nil
        }
        let recorded = model.shortcut(for: .arrange(.left))
        try check(recorded?.label == "⌃⌥⇧F19" && model.recording == nil, "recording assigns the local fixture chord")
        try await click("Shortcut: \(leftAction)")
        try await click("Cancel: \(leftAction)")
        try check(model.shortcut(for: .arrange(.left)) == recorded && model.recording == nil,
                  "canceling a shortcut change preserves the saved key")
        try await click("Disable: \(leftAction)")
        try check(model.shortcut(for: .arrange(.left)) == nil, "disabling a shortcut returns to the recording action")
        try await click("Back")
        try await click("Back")

        try await click("About")
        try verifyHeader(PopoverPage.about.title, hasBack: true)
        try check(verificationRegions[appName] != nil, "About displays the current app name")
        try check(original.frame.width < wide, "About fits in a compact popover")
        try check(verificationURLs.isEmpty, "About waits for link activation")
        try check((try region("Link row")).height == 38 && (try region("Back row")).height == 38,
                  "the link and Back have the same row height")
        snapshot("about")
        try await click("Link row")
        try check(verificationURLs.map(\.absoluteString) == ["https://github.com/mihaliak/awm"],
                  "About link opens the repository destination")
        try await click("Back")

        verificationPages = Array(verificationPages.suffix(1))
        _ = try await dispatchClick("Navigation: Settings")
        try await waitForEntrance(.settings, direction: .forward)
        if reduceMotion() { try await settleMenu() }
        _ = try await dispatchClick("Back row")
        try await waitForEntrance(.home, direction: .backward)
        if reduceMotion() { try await settleMenu() }
        try await click("Navigation: Settings")
        try check(verificationRegions["Navigation: Keyboard Shortcuts"] != nil && verificationRegions["Restore: Focus"] == nil
                  && presentedPage?.surface == .page(.settings) && presentedPage?.opacity == 1
                  && verificationPages.allSatisfy { $0.presentations.count <= 1 } && panel === original && original.isKeyWindow,
                  "rapid forward, back, forward changes leave only the latest page inside the same key panel")
        try await click("Back")

        let oversized = String(repeating: "Wide ", count: 80).trimmingCharacters(in: .whitespaces)
        try check(model.rename(focus, to: oversized), "fixture can edit the workspace name while Home is open")
        try await settleMenu()
        let cap = min(PanelGeometry.maximumWidth, visibleFrame.width)
        try check(original.frame.width == cap && (try region("Text: \(oversized)").height) <= 18,
                  "an exceptionally long name reaches the width cap and stays on one line")
        snapshot("workspace-width-cap")
        try check(model.rename(focus, to: "Focus"), "fixture restores the short workspace name")
        try await Task.sleep(for: .milliseconds(40))
        try check(model.rename(focus, to: oversized), "fixture retargets the popover during a resize")
        try await Task.sleep(for: .milliseconds(40))
        try check(model.rename(focus, to: "Focus"), "fixture retargets the popover back during a resize")
        try await settleMenu()
        try check(original.frame.width == wide && panel === original && original.isKeyWindow,
                  "rapid width changes settle on the latest content and preserve focus")

        try sendKey(kVK_Escape, characters: "\u{1b}", to: original)
        if reduceMotion() {
            try check(!original.isVisible, "reduced-motion panel dismisses immediately")
        }
        try await Task.sleep(for: .milliseconds(160))
        try check(panel == nil && !original.isVisible, "Escape key dismisses the notch")
        try await dispatchStatusAction("reopen action dispatched")
        try await dispatchStatusAction("dismissal action dispatched")
        try await dispatchStatusAction("rapid reopen action dispatched")
        try await settleMenu()
        try check(panel?.isVisible == true && panel?.isKeyWindow == true, "rapid reopen keeps the newest panel visible and key")
        guard let reopened = panel else { throw VerificationFailure(message: "reopened status panel unavailable") }
        try check(reopened.firstResponder === reopened, "reopening the menu leaves focus on the panel")
        try sendKey(kVK_Return, characters: "\r", to: reopened)
        try await settleMenu()
        try check(restoreRequests.isEmpty, "Return after reopening leaves workspaces in place")
        if NSApp.isFullKeyboardAccessEnabled {
            try sendKey(kVK_Tab, characters: "\t", to: reopened)
            try check(reopened.firstResponder !== reopened, "Tab moves keyboard focus into the menu")
            try await settleMenu()
            try sendKey(kVK_Space, characters: " ", to: reopened)
            try await Task.sleep(for: .milliseconds(32))
            try sendKey(kVK_Space, characters: " ", kind: .keyUp, to: reopened)
            try await waitUntil("Space did not activate the focused Restore button (\(restoreRequests.count) actions)") {
                restoreRequests == [focus]
            }
            try check(restoreRequests == [focus], "Space activates Restore after Tab")
        }
        let previousRequests = restoreRequests
        try await click("Restore Active Workspace")
        try check(restoreRequests == previousRequests + [focus], "clicking Restore dispatches one workspace action")

        try await verifyWorkspaceMoves(store: store, focus: focus, longName: longName)
        try check(verificationRegions["Save Current Workspace…"] == nil
                  && verificationRegions["Update Active Workspace…"] == nil,
                  "save and update actions use labels without trailing ellipses")
        try await click("Update Active Workspace")
        try check(verificationRegions["Choose Windows"] != nil, "Update Active Workspace opens the capture review")
        try verifyHeader(PopoverPage.capture.title, hasBack: true)
        let beforeUpdate = try store.load().state.preset(focus)
        try check(verificationRegions["Selected windows: 2"] != nil, "updating initially selects both saved windows")
        try await click("Window: 1", at: .leading)
        try check(verificationRegions["Selected windows: 1"] != nil, "toggling one checkbox leaves one window selected")
        try await click("Update")
        try check(presentedPage?.surface == .page(.home), "updating a capture returns home")
        let afterUpdate = try store.load().state.preset(focus)
        try check(presentedPage?.surface == .page(.home) && afterUpdate?.snapshot.windowCount == 1
                  && afterUpdate?.snapshot.members.first?.windows.first?.frame == beforeUpdate?.snapshot.members.first?.windows.first?.frame
                  && afterUpdate?.name == beforeUpdate?.name && afterUpdate?.icon == beforeUpdate?.icon,
                  "updating the active workspace keeps its name and icon and saves only the selected window")
        try await click("Save Current Workspace")
        try verifyHeader(PopoverPage.home.title, hasWorkspaceActions: true)
        try await verifyWorkspaceDividers(longName, disabled: true)
        guard let editor = panel?.firstResponder as? NSTextView else {
            throw VerificationFailure(message: "workspace name field did not take focus")
        }
        editor.insertText("Review", replacementRange: editor.selectedRange())
        try await click("Windows and icon")
        try await click("Workspace icon")
        try await click("Icon: \(WorkspaceIcon.video.title)")
        try await click("Window: 1", at: .leading)
        snapshot("new-workspace")
        try await click("Save")
        let created = try store.load().state.presets.first { $0.name == "Review" }
        try check(created?.icon == .video && created?.snapshot.windowCount == 1,
                  "capture saves the chosen icon and selected window")
        try check(presentedPage?.surface == .page(.home), "saving a capture returns home")
        guard let vibing = model.state.presets.first(where: { $0.name == "Vibing" }) else {
            throw VerificationFailure(message: "Vibing workspace unavailable after capture")
        }
        let manageClick = try await dispatchClick("Manage: Vibing", at: .leading)
        try await waitUntil("Manage: Vibing at \(manageClick.pointInWindow) in \(manageClick.region) did not show Delete Workspace on the Vibing page (current page \(String(describing: presentedPage?.surface)), panel \(String(describing: panel?.frame)))") {
            presentedPage?.surface == .page(.preset(vibing.id)) && verificationRegions["Delete Workspace…"] != nil
        }
        try await settleMenu()
        try await click("Delete Workspace…")
        _ = try await dispatchClick("Delete")
        try await waitForEntrance(.home, direction: .backward)
        try await settleMenu()
        try check(try store.load().state.presets.allSatisfy { $0.name != "Vibing" },
                  "deleting a workspace returns home")

        try await dispatchStatusAction("close the authorized menu")
        model.verificationAuthorized = false
        try await dispatchStatusAction("open with window control turned off")
        guard let permissionPanel = panel else { throw VerificationFailure(message: "missing permission notch") }
        let arrowAtStart = try await visibleRegion("Permission arrow", in: permissionPanel)
        snapshot("permission-start")
        try await Task.sleep(for: .milliseconds(220))
        snapshot("permission-in-flight")
        try await Task.sleep(for: .milliseconds(400))
        let arrowAtRest = try region("Permission arrow")
        let guide = try region("Window Control Setup")
        let callToAction = try region("Allow Window Control row")
        let finderIcon = try region("Permission Finder icon")
        let appIcon = try region("Permission app icon")
        let settingsIcon = try region("Permission Settings icon")
        try check(finderIcon.maxX < appIcon.minX && appIcon.maxX < arrowAtStart.minX
                  && arrowAtRest.maxX < settingsIcon.minX, "the arrow leads from Finder and the app toward Settings")
        try check(callToAction.height == 38 && guide.contains(callToAction)
                  && (try region("Permission instructions")).maxY < callToAction.minY,
                  "inline permission instructions precede the 38-point action")
        try check(reduceMotion() ? arrowAtStart == arrowAtRest : arrowAtRest.minX > arrowAtStart.minX,
                  reduceMotion() ? "reduced motion shows the permission arrow at rest" : "the permission arrow moves toward Settings")
        try check(handoffs().isEmpty && !ordinaryWindowIsVisible, "permission guidance appears before handoff without a tutorial window")
        snapshot("permission-settled")
        try await verifyHover(on: "Restore: Focus", disabled: true)
        try await click("Settings")
        try await click("Window Control Setup…")
        try check(verificationRegions["Allow Window Control row"] != nil && handoffs().isEmpty,
                  "settings routes to the inline permission guide")
        guard let unauthorizedPanel = panel else { throw VerificationFailure(message: "missing unauthorized notch") }
        try await click("Allow Window Control…")
        try check(handoffs() == [.settings, .finder(Bundle.main.bundleURL)], "permission action opens Settings and reveals the running copy once")
        try check(panel == nil && !unauthorizedPanel.isVisible && !ordinaryWindowIsVisible,
                  "the handoff dismisses the notch and leaves no tutorial window")

        model.verificationAuthorized = true
        try await dispatchStatusAction("reopen after the fixture grants window control")
        try await settleMenu()
        try check(model.authorized && verificationRegions["Window Control Setup"] == nil && handoffs().count == 2,
                  "reopening refreshes permission and clears the inline guidance")

        guard let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: 0, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1) else {
            throw VerificationFailure(message: "fixture outside click unavailable")
        }
        NSApp.sendEvent(outside)
        try await Task.sleep(for: .milliseconds(160))
        try check(panel == nil, "a mouse-down outside the notch dismisses it")
    }

    private var ordinaryWindowIsVisible: Bool {
        NSApp.windows.contains { $0.isVisible && ($0.styleMask.contains(.titled) || ($0 as? NSPanel)?.isFloatingPanel == true) }
    }

    private func verifySizing(store: WorkspaceStore, in panel: NSPanel) async throws {
        let initial = try store.load().state.preferences
        let original = try Data(contentsOf: store.url)
        let field = "Edit: Left width cycle"
        func submitCycle(_ text: String) async throws {
            try await click(field)
            guard let editor = panel.firstResponder as? NSTextView else {
                throw VerificationFailure(message: "sizing cycle did not take focus")
            }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            try sendKey(kVK_Return, characters: "\r", to: panel)
            try await settleMenu()
        }

        try await submitCycle("0%")
        try check(try Data(contentsOf: store.url) == original, "rejecting an invalid width leaves the saved cycle intact")
        try await submitCycle("50%, 100%")
        let preferences = try store.load().state.preferences
        try check(preferences.leftWidths.map(\.fraction) == [0.5, 1] && preferences.rightWidths == initial.rightWidths,
                  "submitting a left width cycle saves it independently of the right cycle")
        try await click("Window gap unit picker", at: .trailing)
        try check(try store.load().state.preferences.windowGapUnit == .points, "switching to points persists the gap unit")
        try await click("Window gap unit picker", at: .leading)
        try check(try store.load().state.preferences.windowGapUnit == .percentage, "switching back persists percentage gaps")
    }
    #endif
}
