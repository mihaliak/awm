import SwiftUI

enum PopoverPage: Hashable {
    case home, settings, shortcuts, sizing, displays, general, about, capture
    case preset(UUID)

    var title: String {
        switch self {
        case .home: "Workspaces"
        case .settings: "Settings"
        case .shortcuts: "Keyboard Shortcuts"
        case .sizing: "Window Sizing"
        case .displays: "Display & Workspace Behavior"
        case .general: "General Preferences"
        case .about: "About"
        case .preset: "Manage Workspace"
        case .capture: "Choose Windows"
        }
    }

    var previous: Self {
        switch self {
        case .home, .settings, .about, .preset, .capture: .home
        case .shortcuts, .sizing, .displays, .general: .settings
        }
    }
}

enum PopoverSurface: Hashable {
    case page(PopoverPage)
    case setupConfirmation
}

enum PageEntrance {
    case stationary, forward, backward

    static let animation = Animation.timingCurve(1.0 / 3, 2.0 / 3, 2.0 / 3, 1, duration: 0.30)

    func presentation(progress: Double, reduceMotion: Bool) -> (offset: CGFloat, opacity: Double) {
        guard self != .stationary, !reduceMotion else { return (0, 1) }
        let remaining = 1 - progress
        return (32 * remaining * (self == .forward ? 1 : -1), 1 - 0.75 * remaining)
    }
}

private struct PopoverRoute {
    let page: PopoverPage
    let entrance: PageEntrance
}

struct PopoverRoot: View {
    private static let horizontalInset: CGFloat = 8
    private static let repository = URL(string: "https://github.com/mihaliak/awm")!

    @ObservedObject var model: AppModel
    let focusedPID: pid_t?
    let visibleFrame: CGRect
    let reducePanelMotion: Bool
    let allowWindowControl: () -> Void
    let quit: () -> Void
    let fitContent: @MainActor (CGSize) -> Void
    #if DEBUG
    var verification: PopoverVerification?
    var rendersWebsiteImage = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var route = PopoverRoute(page: .home, entrance: .stationary)
    @State private var permissionArrowAdvanced = false
    @State private var capture: PresetCapture?
    @State private var captureSource: PopoverPage = .home

    var body: some View {
        #if DEBUG
        if let verification {
            surface
                .coordinateSpace(name: "menu-verification")
                .environment(\.measuresMenuRegions, true)
                .environment(\.menuHoverProbe, verification.hover)
                .environment(\.openURL, verification.openURL)
                .onPreferenceChange(MenuRegionsKey.self, perform: verification.record)
                .onPreferenceChange(MenuMotionKey.self, perform: verification.recordMotion)
                .onPreferenceChange(MenuPagePresentationKey.self, perform: verification.recordPage)
        } else {
            surface
        }
        #else
        surface
        #endif
    }

    private var surface: some View {
        let reducesMotion = reducePanelMotion || reduceMotion
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        return VStack(spacing: 0) {
            header
                .padding(.bottom, MenuMetrics.headerBottomInset)
            GeometryReader { viewport in
                #if DEBUG
                // ImageRenderer draws the shared SwiftUI content without the native scroll container.
                if rendersWebsiteImage {
                    fittedContent.frame(width: viewport.size.width, alignment: .leading)
                } else {
                    scrollingContent(width: viewport.size.width)
                }
                #else
                scrollingContent(width: viewport.size.width)
                #endif
            }
        }
        .padding(.top, PanelGeometry.topInset)
        .environment(\.menuReduceMotion, reducesMotion)
        .tint(MenuPalette.accent)
        .buttonStyle(MenuRowStyle())
        .background(shape.fill(MenuPalette.surface))
        .overlay {
            shape.strokeBorder(MenuPalette.border, lineWidth: 1).allowsHitTesting(false)
        }
        .clipShape(shape)
        .scaleEffect(x: 1, y: revealed || reducesMotion ? 1 : 0.975, anchor: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(reducesMotion ? nil : .timingCurve(0.18, 0.75, 0.25, 1, duration: 0.19)) {
                revealed = true
            }
        }
        .task { await model.watchAccessibility() }
        .task(id: model.authorized) {
            guard !model.authorized, !permissionArrowAdvanced else { return }
            if !reducesMotion {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            permissionArrowAdvanced = true
        }
    }

    private var fittedContent: some View {
        PopoverContentLayout(screenWidth: visibleFrame.width, minimumWidth: preferredWidth) {
            content
        }
    }

    private func scrollingContent(width: CGFloat) -> some View {
        let surface: PopoverSurface = showsSetupConfirmation ? .setupConfirmation : .page(page)
        return ScrollView {
            fittedContent
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    fitContent(CGSize(width: size.width,
                                      height: size.height + MenuMetrics.headerHeight + MenuMetrics.headerBottomInset
                                          + PanelGeometry.topInset))
                }
                .modifier(PageReveal(surface: surface, entrance: showsSetupConfirmation ? .stationary : route.entrance))
                // Keep content on the same leading edge while the panel resizes.
                .frame(width: width, alignment: .leading)
        }
        .id(surface)
    }

    private var page: PopoverPage { route.page }

    private var showsInlineDraft: Bool {
        guard page == .capture, captureSource == .home, let capture else { return false }
        if case .save = capture.mode { return true }
        return false
    }

    private var showsWorkspaceHeader: Bool { page == .home || showsInlineDraft }

    private var preferredWidth: CGFloat {
        showsWorkspaceHeader || page == .displays ? MenuMetrics.workspaceWidth : PanelGeometry.initialSize.width
    }
    private var showsSetupConfirmation: Bool { model.windowControlStage == .confirmation }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsSetupConfirmation {
                WindowControlConfirmation {
                    model.finishWindowControlSetup()
                    if model.windowControlStage == .ready { navigate(.home, .backward, leavingConfirmation: true) }
                }
            } else {
                workspaceContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.horizontalInset)
        .padding(.bottom, Self.horizontalInset)
    }

    @ViewBuilder private var workspaceContent: some View {
        if !model.authorized {
            if page == .home {
                WindowControlSetup(arrowAdvanced: permissionArrowAdvanced, allowWindowControl: allowWindowControl)
            } else {
                Button { navigate(.home, .backward) } label: {
                    MenuRowLabel("Window Control Setup…", icon: "lock.open")
                }
            }
        }
        pageBody
        if page == .home { footer }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("AWMMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 13)
                .accessibilityHidden(true)
                .measuredMenuRegion("AWM header mark")
            if !showsSetupConfirmation && !showsWorkspaceHeader {
                Button {
                    if page == .capture { closeCapture() }
                    else { navigate(page.previous, .backward) }
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(MenuRowStyle(iconOnly: true))
                .frame(width: 26)
                .accessibilityLabel("Back")
                .help("Back")
                .measuredMenuRegion("Back")
                .measuredMenuRegion("Back row")
            }
            let title = showsSetupConfirmation ? "Successfully setup" : showsWorkspaceHeader ? PopoverPage.home.title : page.title
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MenuPalette.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
                .measuredMenuRegion(title)
            if showsWorkspaceHeader, !showsSetupConfirmation, model.authorized {
                let count = model.state.presets.count
                Text("\(count) saved")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(MenuPalette.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("\(count) saved workspaces")
                    .measuredMenuRegion("Saved workspace count")
            }
            Spacer(minLength: 4)
            if showsWorkspaceHeader, !showsSetupConfirmation, model.authorized, let active = model.state.lastActive {
                Button { model.activate(active) } label: {
                    Label("Restore", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize()
                }
                .buttonStyle(MenuRowStyle(centered: true))
                .fixedSize(horizontal: true, vertical: false)
                .disabled(showsInlineDraft)
                .accessibilityLabel("Restore Active Workspace")
                .help("Restore Active Workspace")
                .measuredMenuRegion("Restore Active Workspace")
            }
        }
        .padding(.horizontal, Self.horizontalInset + 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuMetrics.headerHeight)
        .measuredMenuRegion("Page header")
    }

    @ViewBuilder private var pageBody: some View {
        switch page {
        case .home:
            PresetList(model: model, capture: beginCapture) { navigate(.preset($0), .forward) }
        case .settings:
            VStack(spacing: 0) {
                destination("Keyboard Shortcuts", icon: "keyboard", page: .shortcuts)
                MenuSeparator(after: .destination(.shortcuts), before: .destination(.sizing))
                destination("Window Sizing", icon: "arrow.up.left.and.arrow.down.right", page: .sizing)
                MenuSeparator(after: .destination(.sizing), before: .destination(.displays))
                destination("Display & Workspace Behavior", icon: "display.2", page: .displays)
                MenuSeparator(after: .destination(.displays), before: .destination(.general))
                destination("General Preferences", icon: "gearshape", page: .general)
            }
            .menuCard()
        case .shortcuts:
            ShortcutSettings(model: model)
        case .sizing:
            SizingSettings(model: model)
        case .displays:
            DisplaySettings(model: model)
        case .general:
            GeneralSettings(model: model)
        case .about:
            VStack(alignment: .leading, spacing: 9) {
                Text(AWMIdentity.displayName)
                    .font(.headline)
                    .measuredMenuRegion(AWMIdentity.displayName)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .foregroundStyle(MenuPalette.secondary)
                Text("Arrange windows and restore saved workspaces from the menu bar.")
                    .popoverProse()
                Link(destination: Self.repository) {
                    MenuRowLabel("View on GitHub", icon: "arrow.up.right.square")
                }
                .buttonStyle(MenuRowStyle())
                .measuredMenuRegion("Link row")
            }
        case .preset(let id):
            if let preset = model.state.preset(id) {
                PresetDetails(model: model, preset: preset, update: { beginCapture(id) }) { navigate(.home, .backward) }
            }
        case .capture:
            if let capture {
                if showsInlineDraft {
                    PresetList(model: model, capture: beginCapture,
                               manage: { navigate(.preset($0), .forward) }, includesActions: false)
                        .disabled(true)
                        .environment(\.menuKeepsDisabledAppearance, true)
                }
                PresetCaptureView(capture: capture, outsidePolicy: model.state.preferences.outsidePolicy,
                                  canSave: model.authorized && model.canSave, inline: showsInlineDraft,
                                  cancel: closeCapture) { name, selected, icon in
                    if model.saveCapture(capture, name: name, selected: selected, icon: icon) { closeCapture() }
                }
            }
        }
    }

    private func destination(_ title: String, icon: String, page: PopoverPage) -> some View {
        Button { navigate(page, .forward) } label: {
            HStack {
                MenuRowLabel(title, icon: icon)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(MenuPalette.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(MenuRowStyle(inCard: true, cardRow: .destination(page)))
        .measuredMenuRegion("Navigation: \(title)")
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { navigate(.settings, .forward) } label: {
                footerLabel("Settings", icon: "gearshape")
            }
            .measuredMenuRegion("Navigation: Settings")
            .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: 0)
            Button { navigate(.about, .forward) } label: {
                footerLabel("About", icon: "info.circle")
            }
            .measuredMenuRegion("Navigation: About")
            Spacer(minLength: 0)
            Button(action: quit) { footerLabel("Quit", icon: "power") }
                .measuredMenuRegion("Quit row")
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(MenuRowStyle(centered: true, height: 30))
    }

    private func footerLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(MenuPalette.secondary)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize(horizontal: true, vertical: false)
        .measuredMenuRegion(title)
    }

    private func navigate(_ destination: PopoverPage, _ entrance: PageEntrance, leavingConfirmation: Bool = false) {
        guard page != destination || leavingConfirmation else { return }
        model.stopRecording()
        route = PopoverRoute(page: destination, entrance: entrance)
    }

    private func beginCapture(_ id: UUID?) {
        guard let draft = model.beginCapture(updating: id, pid: focusedPID) else { return }
        captureSource = page
        capture = draft
        navigate(.capture, .forward)
    }

    private func closeCapture() {
        capture = nil
        navigate(captureSource, .backward)
    }
}

// A new scroll identity gives each destination its own entrance and resets its scroll position.
private struct PageReveal: ViewModifier {
    let surface: PopoverSurface
    let entrance: PageEntrance
    @Environment(\.menuReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var progress = 0.0

    func body(content: Content) -> some View {
        content
            .modifier(PagePresentation(surface: surface, entrance: entrance, reduceMotion: reduceMotion,
                                       isRightToLeft: layoutDirection == .rightToLeft, progress: progress))
            .task(id: reduceMotion) {
                guard progress == 0 else { return }
                if entrance == .stationary || reduceMotion {
                    progress = 1
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                withAnimation(PageEntrance.animation) { progress = 1 }
            }
    }
}

private struct PagePresentation: ViewModifier, Animatable {
    let surface: PopoverSurface
    let entrance: PageEntrance
    let reduceMotion: Bool
    let isRightToLeft: Bool
    var progress: Double
    #if DEBUG
    @Environment(\.measuresMenuRegions) private var measures
    #endif

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let appearance = entrance.presentation(progress: progress, reduceMotion: reduceMotion)
        let offset = isRightToLeft ? -appearance.offset : appearance.offset
        content
            .opacity(appearance.opacity)
            .offset(x: offset)
            #if DEBUG
            .background {
                if measures {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .named("menu-verification"))
                        Color.clear.preference(key: MenuPagePresentationKey.self, value: [
                            MenuPagePresentation(surface: surface, frame: frame.offsetBy(dx: offset, dy: 0),
                                                 offset: offset, opacity: appearance.opacity)
                        ])
                    }
                }
            }
            #endif
    }
}

private struct PopoverContentLayout: Layout {
    let screenWidth: CGFloat
    let minimumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = PanelGeometry.fittingWidth(max(minimumWidth, content.sizeThatFits(.unspecified).width),
                                               screenWidth: screenWidth)
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: ceil(height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

enum MenuMetrics {
    static let workspaceWidth: CGFloat = 376
    static let headerHeight: CGFloat = 38
    static let headerBottomInset: CGFloat = 4
    static let workspaceRowHeight: CGFloat = 48
    static let rowHeight: CGFloat = 38
}

extension EnvironmentValues {
    @Entry var menuReduceMotion = false
    @Entry var menuKeepsDisabledAppearance = false
}

extension View {
    func menuRowHeight() -> some View {
        frame(height: MenuMetrics.rowHeight)
    }

    func popoverProse() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(idealWidth: 236, alignment: .leading)
    }

    @ViewBuilder fileprivate func menuOpacity(_ value: Double, motion: MenuMotion) -> some View {
        #if DEBUG
        modifier(MeasuredMenuOpacity(value: value, motion: motion))
        #else
        opacity(value)
        #endif
    }

    @ViewBuilder func measuredMenuRegion(_ name: String) -> some View {
        #if DEBUG
        modifier(MenuRegion(name: name))
        #else
        self
        #endif
    }
}

enum MenuMotion {
    case hover

    static let rowHighlight = Animation.easeInOut(duration: 0.12)
}

#if DEBUG
struct PopoverVerification {
    let record: @MainActor ([String: CGRect]) -> Void
    let recordMotion: @MainActor ([MenuMotionSample]) -> Void
    let recordPage: @MainActor ([MenuPagePresentation]) -> Void
    let hover: MenuHoverProbe
    let openURL: OpenURLAction
}

struct MenuPagePresentation: Equatable {
    let surface: PopoverSurface
    let frame: CGRect
    let offset: CGFloat
    let opacity: Double
}

private struct MenuPagePresentationKey: PreferenceKey {
    static let defaultValue: [MenuPagePresentation] = []

    static func reduce(value: inout [MenuPagePresentation], nextValue: () -> [MenuPagePresentation]) {
        value += nextValue()
    }
}

@MainActor
final class MenuHoverProbe: ObservableObject {
    @Published var point: CGPoint?
    @Published var focusPoint: CGPoint?
}

struct MenuMotionSample: Equatable {
    let motion: MenuMotion
    let frame: CGRect
    let opacity: Double
}

private struct MenuMotionKey: PreferenceKey {
    static let defaultValue: [MenuMotionSample] = []

    static func reduce(value: inout [MenuMotionSample], nextValue: () -> [MenuMotionSample]) {
        value += nextValue()
    }
}

private struct MeasuredMenuOpacity: ViewModifier, Animatable {
    var value: Double
    let motion: MenuMotion
    @Environment(\.measuresMenuRegions) private var measures

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(value)
            .background {
                if measures {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .named("menu-verification"))
                        Color.clear.preference(key: MenuMotionKey.self, value: [
                            MenuMotionSample(motion: motion, frame: frame, opacity: value)
                        ])
                    }
                }
            }
    }
}

private struct VerificationHoverTarget: View {
    @ObservedObject var probe: MenuHoverProbe
    let onHover: (Bool) -> Void
    let onFocus: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named("menu-verification"))
            let hovered = probe.point.map(frame.contains) ?? false
            let focused = probe.focusPoint.map(frame.contains) ?? false
            Color.clear
                .onChange(of: hovered, perform: onHover)
                .onChange(of: focused, perform: onFocus)
        }
        .allowsHitTesting(false)
    }
}

private extension EnvironmentValues {
    @Entry var measuresMenuRegions = false
    @Entry var menuHoverProbe: MenuHoverProbe?
}

private struct MenuRegionsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct MenuRegion: ViewModifier {
    @Environment(\.measuresMenuRegions) private var enabled
    let name: String

    func body(content: Content) -> some View {
        if enabled {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MenuRegionsKey.self,
                                           value: [name: geometry.frame(in: .named("menu-verification"))])
                }
            }
        } else {
            content
        }
    }
}
#endif

enum MenuPalette {
    static let accent = color(0x9D84FF)
    static let surface = color(0x1D1728)
    static let card = color(0x282035)
    static let control = color(0x352943)
    static let field = control
    static let text = color(0xF7F2FF)
    static let secondary = color(0xC7BAD6)
    static let selected = color(0x5936C2)
    static let selectedSecondary = color(0xF1E8FF)
    static let border = color(0x49395C)
    static let focus = color(0xD8C8FF)
    static let hover = color(0xEBE0FF)
    static let hoverOpacity = 0.10

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: 1)
    }
}

enum MenuCardRow: Hashable {
    case destination(PopoverPage)
    case workspace(UUID)
    case moveWorkspace(PresetMoveDirection)
    case renameWorkspace, changeWorkspaceIcon, applyWorkspaceIcon, updateWorkspace
}

private struct MenuCardDivider: Hashable {
    let preceding: MenuCardRow?
    let following: MenuCardRow?

    func isVisible(among highlighted: Set<MenuCardRow>) -> Bool {
        ![preceding, following].compactMap { $0 }.contains(where: highlighted.contains)
    }
}

private struct MenuCardDecoration: PreferenceKey {
    var highlighted: Set<MenuCardRow> = []
    var dividerBounds: [MenuCardDivider: Anchor<CGRect>] = [:]

    static var defaultValue: Self { Self() }

    static func reduce(value: inout Self, nextValue: () -> Self) {
        let next = nextValue()
        value.highlighted.formUnion(next.highlighted)
        value.dividerBounds.merge(next.dividerBounds, uniquingKeysWith: { _, bounds in bounds })
    }
}

struct MenuSeparator: View {
    private let divider: MenuCardDivider?

    init(after preceding: MenuCardRow? = nil, before following: MenuCardRow? = nil) {
        divider = preceding == nil && following == nil ? nil
            : MenuCardDivider(preceding: preceding, following: following)
    }

    var body: some View {
        Rectangle()
            .fill(divider == nil ? MenuPalette.border : .clear)
            .frame(height: 1)
            .anchorPreference(key: MenuCardDecoration.self, value: .bounds) { bounds in
                MenuCardDecoration(dividerBounds: divider.map { [$0: bounds] } ?? [:])
            }
            .padding(.horizontal, 14)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct MenuCardDividers: View {
    let decoration: MenuCardDecoration
    @Environment(\.menuReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(decoration.dividerBounds.keys), id: \.self) { divider in
                if let anchor = decoration.dividerBounds[divider] {
                    let bounds = geometry[anchor]
                    let visible = divider.isVisible(among: decoration.highlighted)
                    Rectangle()
                        .fill(MenuPalette.border)
                        .opacity(visible ? 1 : 0)
                        .animation(reduceMotion ? nil : MenuMotion.rowHighlight, value: visible)
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func menuCardHighlight(_ row: MenuCardRow?, isHighlighted: Bool) -> some View {
        transformPreference(MenuCardDecoration.self) { decoration in
            if isHighlighted, let row { decoration.highlighted.insert(row) }
        }
    }

    func menuCard(fill: Color = MenuPalette.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return background(fill, in: shape)
            .overlayPreferenceValue(MenuCardDecoration.self) { decoration in
                MenuCardDividers(decoration: decoration)
            }
            .transformPreference(MenuCardDecoration.self) { $0 = .defaultValue }
            .clipShape(shape)
            .overlay { shape.strokeBorder(MenuPalette.border, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct MenuPrimaryLabel: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .measuredMenuRegion(title)
    }
}

struct MenuRowLabel: View {
    private let title: String
    private let icon: String
    private let active: Bool

    init(_ title: String, icon: String, active: Bool = false) {
        self.title = title
        self.icon = icon
        self.active = active
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? MenuPalette.text : MenuPalette.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .measuredMenuRegion("Text: \(title)")
        }
        .measuredMenuRegion(title)
    }
}

struct ShortcutGlyph: View {
    let key: HotKey
    var active = false

    var body: some View {
        Text(key.label)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(active ? MenuPalette.text : MenuPalette.secondary)
            .fixedSize()
    }
}

struct MenuRowStyle: ButtonStyle {
    var emphasized = false
    var iconOnly = false
    var centered = false
    var primary = false
    var outlined = false
    var inCard = false
    var cardRow: MenuCardRow?
    var height: CGFloat = MenuMetrics.rowHeight

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, style: self)
    }

    private struct Row: View {
        let configuration: Configuration
        let style: MenuRowStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.menuReduceMotion) private var reduceMotion
        @Environment(\.menuKeepsDisabledAppearance) private var keepsDisabledAppearance
        @State private var hovering = false
        #if DEBUG
        @Environment(\.menuHoverProbe) private var hoverProbe
        @State private var verificationFocused = false
        #endif

        private var foreground: Color {
            if configuration.role == .destructive { return Color(red: 1, green: 0.59, blue: 0.59) }
            return style.primary ? MenuPalette.surface : MenuPalette.text
        }

        private var shape: RoundedRectangle {
            // The enclosing card clips the four outer corners of its rows.
            RoundedRectangle(cornerRadius: style.inCard ? 0 : style.primary || style.outlined ? 11 : 8,
                             style: .continuous)
        }

        private var focusVisible: Bool {
            #if DEBUG
            enabled && (focused || verificationFocused)
            #else
            enabled && focused
            #endif
        }

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .padding(.horizontal, style.iconOnly ? 0 : 10)
                .frame(height: style.height)
                .frame(maxWidth: .infinity, alignment: style.iconOnly || style.centered || style.primary ? .center : .leading)
                .background {
                    let fill = style.primary ? MenuPalette.accent : style.outlined ? MenuPalette.control : style.emphasized ? MenuPalette.selected : .clear
                    shape.fill(fill)
                        .overlay {
                            if style.outlined { shape.strokeBorder(MenuPalette.border) }
                        }
                        .overlay {
                            shape.fill(MenuPalette.hover)
                                .menuOpacity(hovering && enabled ? MenuPalette.hoverOpacity : 0, motion: .hover)
                                .animation(reduceMotion ? nil : MenuMotion.rowHighlight, value: hovering)
                        }
                        .overlay {
                            shape.fill(.white.opacity(configuration.isPressed && enabled ? 0.08 : 0))
                        }
                }
                .overlay {
                    shape.strokeBorder((style.primary ? MenuPalette.surface : MenuPalette.focus).opacity(focusVisible ? 1 : 0),
                                       lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .menuCardHighlight(style.cardRow, isHighlighted: enabled && (hovering || configuration.isPressed || focusVisible))
                .opacity(enabled || keepsDisabledAppearance ? 1 : 0.48)
                .onHover { inside in
                    #if DEBUG
                    guard hoverProbe == nil else { return }
                    #endif
                    hovering = inside
                }
                #if DEBUG
                .background {
                    if let hoverProbe {
                        VerificationHoverTarget(probe: hoverProbe) { hovering = $0 } onFocus: { verificationFocused = $0 }
                    }
                }
                #endif
        }
    }
}
