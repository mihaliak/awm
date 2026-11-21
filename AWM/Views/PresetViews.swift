import SwiftUI

struct PresetList: View {
    @ObservedObject var model: AppModel
    let capture: (UUID?) -> Void
    let manage: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.state.presets.isEmpty {
                Text("Arrange your windows, then save their positions as a workspace.")
                    .font(.callout)
                    .foregroundStyle(MenuPalette.secondary)
                    .popoverProse()
                    .padding(.horizontal, 10)
            } else {
                VStack(spacing: 3) {
                    ForEach(model.state.presets) { preset in
                        row(preset)
                    }
                }
            }

            Divider().padding(.vertical, 3)
            Button { capture(nil) } label: {
                MenuRowLabel("Save Current Workspace", icon: "plus")
            }
            .disabled(!model.authorized || !model.canSave)
            if let active = model.state.lastActive {
                Button { capture(active) } label: {
                    MenuRowLabel("Update Active Workspace", icon: "arrow.clockwise")
                }
                .disabled(!model.authorized || !model.canSave)
                Button { model.activate(active) } label: {
                    MenuRowLabel("Restore Active Workspace", icon: "clock.arrow.circlepath")
                }
                .disabled(!model.authorized)
            }
        }
    }

    private func row(_ preset: Preset) -> some View {
        let active = model.state.lastActive == preset.id
        let key = model.shortcut(for: .preset(preset.id))
        let detail = [active ? "Active workspace" : nil, key?.label].compactMap { $0 }.joined(separator: ", ")
        return HStack(spacing: 0) {
            Button { model.activate(preset.id) } label: {
                HStack(spacing: 8) {
                    MenuRowLabel(preset.name, icon: preset.icon.symbol, active: active)
                    Spacer(minLength: 4)
                    if let key {
                        ShortcutGlyph(key: key, active: active)
                    }
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                            .measuredMenuRegion("Active workspace: \(preset.name)")
                    }
                }
            }
            .disabled(!model.authorized)
            .help(active ? "\(preset.name) · Active workspace" : "Restore \(preset.name)")
            .accessibilityLabel(preset.name)
            .accessibilityValue(detail)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityHint("Restores the saved window layout")
            .measuredMenuRegion("Restore: \(preset.name)")
            Button { manage(preset.id) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(active ? .white : MenuPalette.secondary)
            }
            .buttonStyle(MenuRowStyle(iconOnly: true))
            .frame(width: 34)
            .help("Manage \(preset.name)")
            .accessibilityLabel("Manage \(preset.name)")
            .measuredMenuRegion("Manage: \(preset.name)")
        }
        .background(active ? MenuPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct PresetDetails: View {
    enum Edit: Equatable { case none, name, icon, delete }

    @ObservedObject var model: AppModel
    let preset: Preset
    let update: () -> Void
    let onDelete: () -> Void
    @State private var edit: Edit = .none
    @State private var icon = WorkspaceIcon.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                MenuRowLabel(preset.name, icon: preset.icon.symbol)
                    .font(.headline)
                    .textSelection(.enabled)
                    .help(preset.name)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(MenuPalette.secondary)
                    .padding(.leading, 32)
            }
            .padding(.horizontal, 10)
            if edit == .name {
                PresetNameEditor(initialName: preset.name, cancel: { edit = .none }) { name in
                    if model.rename(preset.id, to: name) { edit = .none }
                }
            } else {
                Button { edit = .name } label: { MenuRowLabel("Rename…", icon: "pencil") }
                    .disabled(!model.canSave)
            }
            if edit == .icon {
                WorkspaceIconPicker(selection: $icon)
                Button { edit = .none } label: { MenuRowLabel("Cancel", icon: "xmark") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if model.setIcon(icon, for: preset.id) { edit = .none }
                } label: {
                    MenuRowLabel("Apply Icon", icon: "checkmark")
                }
                .buttonStyle(MenuRowStyle(emphasized: true))
                .disabled(!model.canSave || icon == preset.icon)
            } else {
                Button {
                    icon = preset.icon
                    edit = .icon
                } label: { MenuRowLabel("Change Icon…", icon: "square.grid.2x2") }
                    .disabled(!model.canSave)
            }
            Button(action: update) {
                MenuRowLabel("Update from Current Layout", icon: "arrow.clockwise")
            }
            .disabled(!model.authorized || !model.canSave)
            if model.state.presets.count > 1, let index = model.state.index(ofPreset: preset.id) {
                Divider()
                let position = "Position \(index + 1) of \(model.state.presets.count)"
                Text(position)
                    .font(.caption)
                    .foregroundStyle(MenuPalette.secondary)
                    .padding(.horizontal, 10)
                    .measuredMenuRegion(position)
                moveButton("Move Up", icon: "arrow.up", direction: .up, position: position)
                moveButton("Move Down", icon: "arrow.down", direction: .down, position: position)
            }
            Divider()
            ShortcutRow(model: model, action: .preset(preset.id), title: "Workspace shortcut", icon: "keyboard")
            Divider()
            if edit == .delete {
                Text("Delete “\(preset.name)”?")
                    .font(.callout)
                    .popoverProse()
                    .padding(.horizontal, 10)
                Button { edit = .none } label: { MenuRowLabel("Cancel", icon: "xmark") }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.delete(preset.id)
                    if model.state.preset(preset.id) == nil { onDelete() }
                } label: { MenuRowLabel("Delete", icon: "trash") }
            } else {
                Button(role: .destructive) { edit = .delete } label: {
                    MenuRowLabel("Delete Workspace…", icon: "trash")
                }
                .disabled(!model.canSave)
            }
        }
    }

    private func moveButton(_ title: String, icon: String, direction: PresetMoveDirection, position: String) -> some View {
        Button { model.movePreset(preset.id, direction: direction) } label: {
            MenuRowLabel(title, icon: icon)
        }
        .accessibilityLabel(title)
        .accessibilityValue(position)
        .disabled(!model.canSave || !model.state.canMovePreset(preset.id, direction: direction))
    }

    private var details: String {
        let windows = preset.snapshot.windowCount
        let displays = preset.snapshot.displays.screens.count
        return "\(windows) \(windows == 1 ? "window" : "windows") · \(displays) \(displays == 1 ? "display" : "displays")"
    }
}

struct WorkspaceIconPicker: View {
    @Binding var selection: WorkspaceIcon

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspace icon")
                .font(.callout.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 4) {
                ForEach(WorkspaceIcon.allCases) { icon in
                    Button {
                        selection = icon
                    } label: {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .buttonStyle(MenuRowStyle(emphasized: selection == icon, iconOnly: true))
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .help(icon.title)
                    .accessibilityLabel(icon.title)
                    .accessibilityAddTraits(selection == icon ? .isSelected : [])
                    .measuredMenuRegion("Icon: \(icon.title)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace icon")
            .accessibilityValue(selection.title)
        }
        .padding(.horizontal, 10)
    }
}

private struct PresetNameEditor: View {
    let cancel: () -> Void
    let save: (String) -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(initialName: String, cancel: @escaping () -> Void, save: @escaping (String) -> Void) {
        self.cancel = cancel
        self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                MenuRowLabel("Name", icon: "textformat")
                TextField("Workspace name", text: $name)
                    .accessibilityLabel("Workspace name")
                    .focused($focused)
            }
            .menuRowHeight()
            .padding(.horizontal, 10)
            Button(action: cancel) { MenuRowLabel("Cancel", icon: "xmark") }
                .keyboardShortcut(.cancelAction)
            Button { save(name) } label: { MenuRowLabel("Rename", icon: "checkmark") }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MenuRowStyle(emphasized: true))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { focused = true }
    }
}
