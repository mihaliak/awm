import SwiftUI

struct PresetList: View {
    @ObservedObject var model: AppModel
    let capture: (UUID?) -> Void
    let manage: (UUID) -> Void
    var includesActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.state.presets.isEmpty {
                Text("Arrange your windows, then save their positions as a workspace.")
                    .font(.callout)
                    .foregroundStyle(MenuPalette.secondary)
                    .popoverProse()
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .menuCard()
            } else {
                let presets = model.state.presets
                VStack(spacing: 0) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 {
                            MenuSeparator(after: .workspace(presets[index - 1].id), before: .workspace(preset.id))
                        }
                        row(preset)
                    }
                }
                .menuCard()
            }

            if includesActions {
                Button { capture(nil) } label: {
                    MenuPrimaryLabel("Save Current Workspace", icon: "plus")
                }
                .buttonStyle(MenuRowStyle(centered: true, outlined: true, height: 38))
                .disabled(!model.authorized || !model.canSave)

                if let active = model.state.lastActive {
                    Button { capture(active) } label: {
                        MenuRowLabel("Update Active Workspace", icon: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(MenuRowStyle(centered: true, height: 30))
                    .disabled(!model.authorized || !model.canSave)
                }
            }
        }
    }

    private func row(_ preset: Preset) -> some View {
        let active = model.state.lastActive == preset.id
        let cardRow = MenuCardRow.workspace(preset.id)
        let key = model.shortcut(for: .preset(preset.id))
        let windows = preset.snapshot.windowCount
        let windowCount = "\(windows) \(windows == 1 ? "window" : "windows")"
        let detail = [windowCount, active ? "Active workspace" : nil, key?.label].compactMap { $0 }.joined(separator: ", ")
        return HStack(spacing: 0) {
            Button { model.activate(preset.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: preset.icon.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(active ? MenuPalette.text : MenuPalette.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.system(size: 13, weight: active ? .medium : .regular))
                            .lineLimit(1)
                            .measuredMenuRegion("Text: \(preset.name)")
                        Text(active ? "\(windowCount) · Active" : windowCount)
                            .font(.system(size: 12))
                            .foregroundStyle(active ? MenuPalette.selectedSecondary : MenuPalette.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    if let key { ShortcutGlyph(key: key, active: active) }
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MenuPalette.text)
                            .accessibilityHidden(true)
                            .measuredMenuRegion("Active workspace: \(preset.name)")
                    }
                }
                .padding(.leading, 4)
            }
            .buttonStyle(MenuRowStyle(inCard: true, cardRow: cardRow, height: MenuMetrics.workspaceRowHeight))
            .disabled(!model.authorized)
            .help(active ? "\(preset.name) · Active workspace" : "Restore \(preset.name)")
            .accessibilityLabel(preset.name)
            .accessibilityValue(detail)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityHint("Restores the saved window layout")
            .measuredMenuRegion("Restore: \(preset.name)")
            Button { manage(preset.id) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? MenuPalette.selectedSecondary : MenuPalette.secondary)
            }
            .buttonStyle(MenuRowStyle(iconOnly: true, inCard: true, cardRow: cardRow, height: MenuMetrics.workspaceRowHeight))
            .frame(width: 44)
            .help("Manage \(preset.name)")
            .accessibilityLabel("Manage \(preset.name)")
            .measuredMenuRegion("Manage: \(preset.name)")
        }
        .background(active ? MenuPalette.selected : .clear, in: Rectangle())
        .menuCardHighlight(cardRow, isHighlighted: active)
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
            VStack(alignment: .leading, spacing: 0) {
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
                .padding(10)
                MenuSeparator()
                workspaceActions
            }
            .menuCard()

            if model.state.presets.count > 1, let index = model.state.index(ofPreset: preset.id) {
                let position = "Position \(index + 1) of \(model.state.presets.count)"
                VStack(alignment: .leading, spacing: 0) {
                    Text(position)
                        .font(.caption)
                        .foregroundStyle(MenuPalette.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .measuredMenuRegion(position)
                    moveButton("Move Up", icon: "arrow.up", direction: .up, position: position)
                    MenuSeparator(after: .moveWorkspace(.up), before: .moveWorkspace(.down))
                    moveButton("Move Down", icon: "arrow.down", direction: .down, position: position)
                }
                .menuCard()
            }

            ShortcutRow(model: model, action: .preset(preset.id), title: "Workspace shortcut", icon: "keyboard")
                .padding(.top, 10)
                .menuCard()

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

    private var workspaceActions: some View {
        VStack(spacing: 0) {
            if edit == .name {
                PresetNameEditor(initialName: preset.name, cancel: { edit = .none }) { name in
                    if model.rename(preset.id, to: name) { edit = .none }
                }
                .padding(.vertical, 8)
            } else {
                Button { edit = .name } label: { MenuRowLabel("Rename…", icon: "pencil") }
                    .buttonStyle(MenuRowStyle(inCard: true, cardRow: .renameWorkspace))
                    .disabled(!model.canSave)
            }
            MenuSeparator(after: edit == .name ? nil : .renameWorkspace,
                          before: edit == .icon ? nil : .changeWorkspaceIcon)
            if edit == .icon {
                WorkspaceIconPicker(selection: $icon)
                    .padding(.top, 10)
                Button { edit = .none } label: { MenuRowLabel("Cancel", icon: "xmark") }
                    .buttonStyle(MenuRowStyle(inCard: true))
                    .keyboardShortcut(.cancelAction)
                Button {
                    if model.setIcon(icon, for: preset.id) { edit = .none }
                } label: {
                    MenuRowLabel("Apply Icon", icon: "checkmark", active: true)
                }
                .buttonStyle(MenuRowStyle(emphasized: true, inCard: true, cardRow: .applyWorkspaceIcon))
                .disabled(!model.canSave || icon == preset.icon)
            } else {
                Button {
                    icon = preset.icon
                    edit = .icon
                } label: { MenuRowLabel("Change Icon…", icon: "square.grid.2x2") }
                .buttonStyle(MenuRowStyle(inCard: true, cardRow: .changeWorkspaceIcon))
                    .disabled(!model.canSave)
            }
            MenuSeparator(after: edit == .icon ? .applyWorkspaceIcon : .changeWorkspaceIcon,
                          before: .updateWorkspace)
            Button(action: update) {
                MenuRowLabel("Update from Current Layout", icon: "arrow.clockwise")
            }
            .buttonStyle(MenuRowStyle(inCard: true, cardRow: .updateWorkspace))
            .disabled(!model.authorized || !model.canSave)
        }
    }

    private func moveButton(_ title: String, icon: String, direction: PresetMoveDirection, position: String) -> some View {
        Button { model.movePreset(preset.id, direction: direction) } label: {
            MenuRowLabel(title, icon: icon)
        }
        .buttonStyle(MenuRowStyle(inCard: true, cardRow: .moveWorkspace(direction)))
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
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text("Workspace icon")
                    .font(.callout.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 4) {
                ForEach(WorkspaceIcon.allCases) { icon in
                    Button {
                        selection = icon
                    } label: {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .buttonStyle(MenuRowStyle(emphasized: selection == icon, iconOnly: true))
                    .background(MenuPalette.control, in: RoundedRectangle(cornerRadius: 8))
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
            Button { save(name) } label: { MenuRowLabel("Rename", icon: "checkmark", active: true) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MenuRowStyle(emphasized: true))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { focused = true }
    }
}
