import SwiftUI

struct PresetCaptureView: View {
    let capture: PresetCapture
    let outsidePolicy: OutsidePolicy
    let canSave: Bool
    let inline: Bool
    let cancel: () -> Void
    let save: (String, Set<UUID>, WorkspaceIcon) -> Void
    @State private var selected: Set<UUID>
    @State private var name = ""
    @State private var icon: WorkspaceIcon
    @State private var showsIconPicker = false
    @State private var showsDetails = false
    @FocusState private var nameFocused: Bool

    init(capture: PresetCapture, outsidePolicy: OutsidePolicy, canSave: Bool, inline: Bool,
         cancel: @escaping () -> Void, save: @escaping (String, Set<UUID>, WorkspaceIcon) -> Void) {
        self.capture = capture
        self.outsidePolicy = outsidePolicy
        self.canSave = canSave
        self.inline = inline
        self.cancel = cancel
        self.save = save
        _selected = State(initialValue: capture.initialSelection)
        _icon = State(initialValue: capture.initialIcon)
    }

    var body: some View {
        Group {
            if inline {
                inlineDraft
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    workspace
                    windowSelection
                    restorePolicy
                    HStack(spacing: 8) {
                        cancelButton
                        saveButton
                    }
                }
            }
        }
        .onAppear {
            if case .save = capture.mode { nameFocused = true }
        }
    }

    private var inlineDraft: some View {
        VStack(alignment: .leading, spacing: 6) {
            nameLabel
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    nameField.frame(minWidth: 126)
                    saveButton.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    nameField
                    saveButton
                }
            }
            HStack(spacing: 8) {
                Button {
                    showsDetails.toggle()
                } label: {
                    Label("Windows and icon", systemImage: showsDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12))
                        .fixedSize()
                }
                .buttonStyle(MenuRowStyle(height: 34))
                .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
                .measuredMenuRegion("Windows and icon")
                Spacer(minLength: 0)
                cancelButton
            }
            if showsDetails {
                iconSelection
                windowSelection
                restorePolicy
            }
        }
        .padding(12)
        .menuCard(fill: MenuPalette.surface)
    }

    private var nameLabel: some View {
        Text("Workspace name")
            .font(.system(size: 12))
            .foregroundStyle(MenuPalette.secondary)
            .accessibilityHidden(true)
    }

    private var nameField: some View {
        TextField("Workspace name", text: $name, prompt: Text("Enter a name"))
            .textFieldStyle(.plain)
            .accessibilityLabel("Workspace name")
            .focused($nameFocused)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(MenuPalette.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(nameFocused ? MenuPalette.focus : MenuPalette.border, lineWidth: nameFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .measuredMenuRegion("Workspace name")
    }

    private var iconSelection: some View {
        VStack(spacing: 0) {
            Button {
                showsIconPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    MenuRowLabel("Workspace icon", icon: icon.symbol)
                    Spacer(minLength: 4)
                    Text(icon.title)
                        .font(.caption)
                        .foregroundStyle(MenuPalette.secondary)
                    Image(systemName: showsIconPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MenuPalette.secondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(icon.title)
            if showsIconPicker {
                WorkspaceIconPicker(selection: $icon, showsTitle: false)
                    .padding(.bottom, 10)
            }
        }
    }

    private var windowSelection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Windows")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text("\(selected.count) of \(capture.snapshot.windowCount) selected")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(MenuPalette.secondary)
                    .measuredMenuRegion("Selected windows: \(selected.count)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            ForEach(capture.snapshot.members) { member in
                MenuSeparator()
                appGroup(member)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .menuCard()
    }

    private var restorePolicy: some View {
        Text("On restore · \(outsidePolicy.label)")
            .font(.caption)
            .foregroundStyle(MenuPalette.secondary)
            .padding(.horizontal, 10)
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Text("Cancel")
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
                .measuredMenuRegion("Cancel")
        }
        .buttonStyle(MenuRowStyle(centered: true, height: 34))
        .fixedSize()
        .keyboardShortcut(.cancelAction)
    }

    private var saveButton: some View {
        Button { save(name, selected, icon) } label: {
            Text(capture.mode.action)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, inline ? 12 : 0)
                .measuredMenuRegion(capture.mode.action)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(MenuRowStyle(primary: true, height: 36))
        .disabled(!canSave || selected.isEmpty || needsName)
    }

    @ViewBuilder private var workspace: some View {
        if case .update(_, let name) = capture.mode {
            MenuRowLabel(name, icon: capture.initialIcon.symbol)
                .font(.headline)
                .help(name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .menuCard()
        }
    }

    private func appGroup(_ member: SavedApp) -> some View {
        let included = member.windows.filter { selected.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(sources: member.windows.map { selection(for: $0.id) }, isOn: \.self) {
                HStack {
                    MenuRowLabel(member.identity.name, icon: "app").fontWeight(.semibold)
                    Spacer()
                    Text("\(included)/\(member.windows.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(MenuPalette.secondary)
                        .accessibilityLabel("\(included) of \(member.windows.count) windows selected")
                }
            }
            .menuRowHeight()
            ForEach(member.windows) { window in
                let location = capture.location(of: window)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: selection(for: window.id)) {
                        MenuRowLabel(member.windowLabel(for: window), icon: "macwindow")
                    }
                    .accessibilityHint(location)
                    .measuredMenuRegion("Window: \(window.order)")
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(MenuPalette.secondary)
                        .popoverProse()
                        .padding(.leading, 52)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 20)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func selection(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { checked in
                if checked { selected.insert(id) }
                else { selected.remove(id) }
            }
        )
    }

    private var needsName: Bool {
        guard case .save = capture.mode else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
