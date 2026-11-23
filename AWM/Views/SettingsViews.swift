import ServiceManagement
import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                heading("Window actions")
                ForEach(ArrangementAction.allCases) { action in
                    ShortcutRow(model: model, action: .arrange(action), title: action.label, icon: action.symbol)
                }
                Button { model.resetShortcuts() } label: {
                    MenuRowLabel("Reset Window Shortcuts", icon: "arrow.counterclockwise")
                }
                .disabled(!model.canSave || model.recording != nil)
            }
            if !model.state.presets.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    heading("Workspaces")
                    ForEach(model.state.presets) { preset in
                        ShortcutRow(model: model, action: .preset(preset.id), title: preset.name, icon: preset.icon.symbol)
                    }
                }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 10)
    }
}

private extension ArrangementAction {
    var symbol: String {
        switch self {
        case .left: "arrow.left.to.line"
        case .right: "arrow.right.to.line"
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        case .center: "arrow.up.left.and.arrow.down.right"
        case .centerWithoutResizing: "viewfinder"
        }
    }
}

struct ShortcutRow: View {
    private static let actionIndent: CGFloat = 22

    @ObservedObject var model: AppModel
    let action: ShortcutAction
    let title: String
    let icon: String

    var body: some View {
        let key = model.shortcut(for: action)
        let recording = model.recording == action
        let target = model.state.shortcutName(action)
        VStack(alignment: .leading, spacing: 6) {
            MenuRowLabel(title, icon: icon)
                .font(.callout.weight(.medium))
                .accessibilityAddTraits(.isHeader)
                .help(title)
                .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 6) {
                if recording {
                    Text("Press a key with a modifier.")
                        .font(.callout)
                        .foregroundStyle(MenuPalette.secondary)
                        .padding(.leading, 10)
                    Button { model.stopRecording() } label: {
                        MenuRowLabel("Cancel Recording", icon: "xmark")
                    }
                    .measuredMenuRegion("Cancel: \(target)")
                } else {
                    Button {
                        model.beginRecording(action)
                    } label: {
                        HStack {
                            MenuRowLabel(key == nil ? "Record…" : "Change Shortcut…", icon: "keyboard")
                            Spacer(minLength: 4)
                            if let key { ShortcutGlyph(key: key) }
                        }
                    }
                    .accessibilityLabel(key.map { "Change shortcut for \(target), \($0.label)" } ?? "Record shortcut for \(target)")
                    .measuredMenuRegion("Shortcut: \(target)")
                    if key != nil {
                        Button { model.assign(nil, to: action) } label: {
                            MenuRowLabel("Disable Shortcut", icon: "minus.circle")
                        }
                        .accessibilityLabel("Disable shortcut for \(target)")
                        .measuredMenuRegion("Disable: \(target)")
                    }
                }
            }
            .padding(.leading, Self.actionIndent)
        }
        .disabled(!model.canSave)
    }
}

struct SizingSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SequenceEditor(title: "Left width cycle", icon: "arrow.left.to.line", values: model.state.preferences.leftWidths) {
                    model.saveCycle($0, at: \.leftWidths)
                }
                SequenceEditor(title: "Right width cycle", icon: "arrow.right.to.line", values: model.state.preferences.rightWidths) {
                    model.saveCycle($0, at: \.rightWidths)
                }
                SequenceEditor(title: "Top height cycle", icon: "arrow.up.to.line", values: model.state.preferences.topHeights) {
                    model.saveCycle($0, at: \.topHeights)
                }
                SequenceEditor(title: "Bottom height cycle", icon: "arrow.down.to.line", values: model.state.preferences.bottomHeights) {
                    model.saveCycle($0, at: \.bottomHeights)
                }
                SettingsNote("Enter 1–12 fractions or percentages from 10% to 100%, separated by commas.")
            }
            Divider()
            windowGap
            Stepper(value: Binding(get: { model.state.preferences.marginPercent },
                                   set: { model.set(\.marginPercent, $0) }), in: 0...40) {
                HStack {
                    MenuRowLabel("Centered window margin", icon: "viewfinder")
                    Spacer(minLength: 4)
                    Text("\(model.state.preferences.marginPercent)%")
                        .monospacedDigit().foregroundStyle(MenuPalette.secondary)
                }
            }
            .menuRowHeight()
            .padding(.horizontal, 10)
            SettingsNote("Margin per edge for the almost-full size. Uses the window gap if it’s larger.")
            SettingsSwitch("Animate window movement", icon: "sparkles",
                           isOn: Binding(get: { model.state.preferences.animate },
                                         set: { model.set(\.animate, $0) }))
        }
        .disabled(!model.canSave)
    }

    private var windowGap: some View {
        let usesPoints = model.state.preferences.windowGapUnit == .points
        let keyPath: WritableKeyPath<Preferences, Int> = usesPoints ? \.windowGapPoints : \.windowGapPercent
        let range = usesPoints ? Preferences.windowGapPointsRange : Preferences.windowGapPercentRange
        let value = model.state.preferences[keyPath: keyPath]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                MenuRowLabel("Gap unit", icon: "ruler")
                Spacer(minLength: 4)
                Picker("Window gap unit", selection: Binding(get: { model.state.preferences.windowGapUnit }, set: { unit in
                    // The native segmented picker can write its binding during a SwiftUI update.
                    Task { @MainActor in model.set(\.windowGapUnit, unit) }
                })) {
                    ForEach(WindowGapUnit.allCases) { unit in Text(unit.label).tag(unit) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .measuredMenuRegion("Window gap unit picker")
            }
            .menuRowHeight()
            .padding(.horizontal, 10)
            Stepper(value: Binding(get: { model.state.preferences[keyPath: keyPath] },
                                   set: { model.set(keyPath, $0) }), in: range) {
                HStack {
                    MenuRowLabel("Window gap", icon: "arrow.left.and.right")
                    Spacer(minLength: 4)
                    Text(usesPoints ? "\(value) pt" : "\(value)%")
                        .monospacedDigit().foregroundStyle(MenuPalette.secondary)
                }
            }
            .menuRowHeight()
            .padding(.horizontal, 10)
            SettingsNote(usesPoints
                 ? "Space between tiles and along display edges, capped at 8% of the shorter usable display dimension."
                 : "Space between tiles and along display edges, based on the usable width or height.")
        }
    }
}

private struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(MenuPalette.secondary)
            .popoverProse()
            .padding(.leading, 42)
            .padding(.trailing, 10)
    }
}

private struct SequenceEditor: View {
    let title: String
    let icon: String
    let values: [WindowFraction]
    let save: (String) -> [WindowFraction]?
    @State private var draft: String

    init(title: String, icon: String, values: [WindowFraction], save: @escaping (String) -> [WindowFraction]?) {
        self.title = title
        self.icon = icon
        self.values = values
        self.save = save
        _draft = State(initialValue: Self.summary(values))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MenuRowLabel(title, icon: icon)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
            TextField(title, text: $draft)
                .accessibilityLabel(title)
                .onSubmit(apply)
                .menuRowHeight()
                .measuredMenuRegion("Edit: \(title)")
                .padding(.leading, 42)
                .padding(.trailing, 10)
            Button(action: apply) { MenuRowLabel("Apply", icon: "checkmark") }
                .disabled(draft == Self.summary(values))
                .accessibilityLabel("Apply \(title)")
        }
        .onChange(of: values) { draft = Self.summary($0) }
    }

    private func apply() {
        if let parsed = save(draft) { draft = Self.summary(parsed) }
    }

    private static func summary(_ values: [WindowFraction]) -> String {
        values.map(\.entry).joined(separator: ", ")
    }
}

struct DisplaySettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                settingText("Other apps", note: "When restoring a workspace")
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                Menu {
                    Picker("Other apps", selection: binding(\.outsidePolicy)) {
                        ForEach(OutsidePolicy.allCases) { policy in Text(policy.label).tag(policy) }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 8) {
                        Text(model.state.preferences.outsidePolicy.label)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MenuPalette.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(MenuPalette.control, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(MenuPalette.border).allowsHitTesting(false) }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Other apps")
                .accessibilityValue(model.state.preferences.outsidePolicy.label)
            }
            .frame(minHeight: MenuMetrics.workspaceRowHeight)
            .padding(.horizontal, 14)
            MenuSeparator()
            SettingsSwitch("Launch missing apps", icon: nil, isOn: binding(\.launchMissing))
            SettingsSwitch("Show apps and windows during restore", icon: nil, isOn: binding(\.revealMembers),
                           note: "Unhide apps and restore minimized windows.")
                .help("Show hidden apps, restore minimized windows, and ask running apps to show their withdrawn windows.")
            MenuSeparator()
            Text("Display changes")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MenuPalette.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            SettingsSwitch("Restore a workspace when displays change", icon: nil, isOn: binding(\.autoActivate),
                           note: "Choose one workspace per display arrangement.")
            if model.state.presets.isEmpty {
                SettingsNote("Save a workspace to associate it with your displays.")
                    .padding(.bottom, 8)
            }
            ForEach(model.state.presets) { preset in
                SettingsSwitch(preset.name, icon: nil, isOn: Binding(
                    get: { model.state.preset(preset.id)?.followsDisplays ?? false },
                    set: { model.associate(preset.id, enabled: $0) }
                ), note: (preset.automaticLayout ?? preset.snapshot.displays).screens.map(\.name).joined(separator: ", "))
                .help(preset.name)
            }
        }
        .menuCard()
        .disabled(!model.canSave)
    }

    private func binding<Value: Equatable>(_ key: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { model.state.preferences[keyPath: key] }, set: { model.set(key, $0) })
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSwitch("Launch at login", icon: "power", isOn: Binding(
                get: { model.state.preferences.launchAtLogin },
                set: { model.setLogin($0) }
            ))
            .disabled(!model.canSave)
            if model.loginStatus == .requiresApproval {
                Button { model.openLoginSettings() } label: {
                    MenuRowLabel("Approve in Login Items…", icon: "checkmark.shield")
                }
                .buttonStyle(MenuRowStyle(inCard: true))
            }
            MenuSeparator()
            SettingsSwitch("Restore last active workspace on launch", icon: "clock.arrow.circlepath", isOn: Binding(
                get: { model.state.preferences.restoreOnLaunch },
                set: { model.set(\.restoreOnLaunch, $0) }
            ))
            .disabled(!model.canSave)
        }
        .menuCard()
    }
}

@MainActor
private func settingText(_ title: String, note: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .measuredMenuRegion("Text: \(title)")
        if let note, !note.isEmpty {
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(MenuPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsSwitch: View {
    @Environment(\.isEnabled) private var enabled

    let title: String
    let icon: String?
    let isOn: Binding<Bool>
    let note: String?

    init(_ title: String, icon: String?, isOn: Binding<Bool>, note: String? = nil) {
        self.title = title
        self.icon = icon
        self.isOn = isOn
        self.note = note
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MenuPalette.secondary)
                        .frame(width: 22)
                }
                settingText(title, note: note)
            }
            .accessibilityHidden(true)
            .onTapGesture {
                if enabled { isOn.wrappedValue.toggle() }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .toggleStyle(MenuToggleStyle())
                .accessibilityHint(note ?? "")
                .fixedSize()
        }
        .padding(.vertical, note == nil ? 0 : 7)
        .frame(minHeight: icon == nil ? MenuMetrics.workspaceRowHeight : MenuMetrics.rowHeight)
        .measuredMenuRegion("Switch: \(title)")
        .padding(.horizontal, 14)
        .measuredMenuRegion("Switch group: \(title)")
    }
}

private struct MenuToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? MenuPalette.accent : MenuPalette.control)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? MenuPalette.surface : MenuPalette.secondary)
                        .frame(width: 15, height: 15)
                        .padding(4)
                }
                .frame(width: 38, height: 23)
        }
        .buttonStyle(SwitchButtonStyle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }

    private struct SwitchButtonStyle: ButtonStyle {
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        private var focusBorder: Color { MenuPalette.focus.opacity(focused ? 1 : 0) }

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .overlay {
                    Capsule().inset(by: -2).strokeBorder(focusBorder, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .opacity(enabled && !configuration.isPressed ? 1 : 0.6)
        }
    }
}
