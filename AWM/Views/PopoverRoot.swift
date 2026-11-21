import SwiftUI

let awmDisplayName = "Another Window Management"

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
    private static let horizontalInset: CGFloat = 14
    private static let repository = URL(string: "https://github.com/mihaliak/awm")!

    @ObservedObject var model: AppModel
    let focusedPID: pid_t?
    let anchorX: CGFloat
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
        let shape = NotchShape(anchorX: anchorX, visibleFrame: visibleFrame)
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
        .padding(.top, NotchGeometry.topInset)
        .environment(\.menuReduceMotion, reducesMotion)
        .tint(MenuPalette.accent)
        .buttonStyle(MenuRowStyle())
        .background(shape.fill(MenuPalette.surface))
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
        PopoverContentLayout(screenWidth: visibleFrame.width) {
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
                                          + NotchGeometry.topInset))
                }
                .modifier(PageReveal(surface: surface, entrance: showsSetupConfirmation ? .stationary : route.entrance))
                // Keep content on the same leading edge while the panel resizes.
                .frame(width: width, alignment: .leading)
        }
        .id(surface)
    }

    private var page: PopoverPage { route.page }
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
        .padding(.bottom, 14)
    }

    @ViewBuilder private var workspaceContent: some View {
        if page != .home {
            Button {
                if page == .capture { closeCapture() }
                else { navigate(page.previous, .backward) }
            } label: {
                MenuRowLabel("Back", icon: "chevron.left")
            }
            .measuredMenuRegion("Back row")
        }
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
        if page == .home {
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("AWMMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 13)
                .accessibilityHidden(true)
            Text(showsSetupConfirmation ? "Successfully setup" : page.title)
                .font(.system(size: showsSetupConfirmation ? 15 : 13, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .measuredMenuRegion(showsSetupConfirmation ? "Successfully setup" : page.title)
        }
        .padding(.horizontal, Self.horizontalInset + 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuMetrics.headerHeight)
        .measuredMenuRegion("Page header")
    }

    @ViewBuilder private var pageBody: some View {
        switch page {
        case .home:
            PresetList(model: model, capture: beginCapture) { navigate(.preset($0), .forward) }
        case .settings:
            VStack(spacing: 3) {
                destination("Keyboard Shortcuts", icon: "keyboard", page: .shortcuts)
                destination("Window Sizing", icon: "arrow.up.left.and.arrow.down.right", page: .sizing)
                destination("Display & Workspace Behavior", icon: "display.2", page: .displays)
                destination("General Preferences", icon: "gearshape", page: .general)
            }
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
                Text(awmDisplayName)
                    .font(.headline)
                    .measuredMenuRegion(awmDisplayName)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .foregroundStyle(.secondary)
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
                PresetCaptureView(capture: capture, outsidePolicy: model.state.preferences.outsidePolicy,
                                  canSave: model.authorized && model.canSave,
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
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .measuredMenuRegion("Navigation: \(title)")
    }

    private var footer: some View {
        VStack(spacing: 5) {
            destination("Settings", icon: "gearshape", page: .settings)
                .keyboardShortcut(",", modifiers: .command)
            destination("About", icon: "info.circle", page: .about)
            Button(action: quit) { MenuRowLabel("Quit", icon: "power") }
                .measuredMenuRegion("Quit row")
                .keyboardShortcut("q", modifiers: .command)
        }
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = NotchGeometry.fittingWidth(content.sizeThatFits(.unspecified).width, screenWidth: screenWidth)
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: ceil(height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

enum MenuMetrics {
    static let headerHeight: CGFloat = 38
    static let headerBottomInset: CGFloat = 8
    static let rowHeight: CGFloat = 38
}

extension EnvironmentValues {
    @Entry var menuReduceMotion = false
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

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named("menu-verification"))
            let hovered = probe.point.map(frame.contains) ?? false
            Color.clear.onChange(of: hovered, perform: onHover)
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
    static let accent = Color(.sRGB, red: 157.0 / 255, green: 132.0 / 255, blue: 1, opacity: 1)
    static let surface = Color(.sRGB, red: 0.115, green: 0.089, blue: 0.157, opacity: 1)
    static let secondary = Color(.sRGB, red: 0.78, green: 0.73, blue: 0.84, opacity: 1)
    static let selected = Color(.sRGB, red: 0.35, green: 0.21, blue: 0.76, opacity: 1)
    static let hover = Color(.sRGB, red: 0.92, green: 0.88, blue: 1, opacity: 1)
    static let hoverOpacity = 0.10
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
                .foregroundStyle(active ? .white : MenuPalette.secondary)
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
            .foregroundStyle(active ? .white : MenuPalette.secondary)
            .fixedSize()
    }
}

struct MenuRowStyle: ButtonStyle {
    var emphasized = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, style: self)
    }

    private struct Row: View {
        let configuration: Configuration
        let style: MenuRowStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.menuReduceMotion) private var reduceMotion
        @State private var hovering = false
        #if DEBUG
        @Environment(\.menuHoverProbe) private var hoverProbe
        #endif

        var body: some View {
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? Color(red: 1, green: 0.59, blue: 0.59) : .white)
                .padding(.horizontal, style.iconOnly ? 0 : 10)
                .menuRowHeight()
                .frame(maxWidth: .infinity, alignment: style.iconOnly ? .center : .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 8)
                    shape.fill(style.emphasized ? MenuPalette.selected : .clear)
                        .overlay {
                            shape.fill(MenuPalette.hover)
                                .menuOpacity(hovering && enabled ? MenuPalette.hoverOpacity : 0, motion: .hover)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovering)
                        }
                        .overlay {
                            shape.fill(.white.opacity(configuration.isPressed && enabled ? 0.15 : 0))
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(MenuPalette.accent.opacity(focused ? 1 : 0), lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.48)
                .onHover { inside in
                    #if DEBUG
                    guard hoverProbe == nil else { return }
                    #endif
                    hovering = inside
                }
                #if DEBUG
                .background {
                    if let hoverProbe {
                        VerificationHoverTarget(probe: hoverProbe) { hovering = $0 }
                    }
                }
                #endif
        }
    }
}

private struct NotchShape: Shape {
    let anchorX: CGFloat
    let visibleFrame: CGRect

    func path(in rect: CGRect) -> Path {
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY + NotchGeometry.topInset
        let bottom = max(top, rect.maxY)
        let pointerX = anchorX - NotchGeometry.leadingEdge(anchorX: anchorX, visibleFrame: visibleFrame, width: rect.width)
        let pointer = NotchGeometry.pointer(in: rect, anchorX: rect.minX + pointerX, bodyHeight: bottom - top)
        let radius = pointer.radius
        return Path { path in
            path.move(to: CGPoint(x: left + radius, y: top))
            path.addLine(to: CGPoint(x: pointer.base - pointer.halfWidth, y: top))
            path.addLine(to: CGPoint(x: pointer.tip, y: rect.minY + NotchGeometry.topAir))
            path.addLine(to: CGPoint(x: pointer.base + pointer.halfWidth, y: top))
            path.addLine(to: CGPoint(x: right - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: left + radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: left, y: bottom - radius), control: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: left, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
            path.closeSubpath()
        }
    }
}
