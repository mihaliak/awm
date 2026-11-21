import SwiftUI

struct PresetCaptureView: View {
    let capture: PresetCapture
    let outsidePolicy: OutsidePolicy
    let canSave: Bool
    let cancel: () -> Void
    let save: (String, Set<UUID>, WorkspaceIcon) -> Void
    @State private var selected: Set<UUID>
    @State private var name = ""
    @State private var icon: WorkspaceIcon
    @FocusState private var nameFocused: Bool

    init(capture: PresetCapture, outsidePolicy: OutsidePolicy, canSave: Bool,
         cancel: @escaping () -> Void, save: @escaping (String, Set<UUID>, WorkspaceIcon) -> Void) {
        self.capture = capture
        self.outsidePolicy = outsidePolicy
        self.canSave = canSave
        self.cancel = cancel
        self.save = save
        _selected = State(initialValue: capture.initialSelection)
        _icon = State(initialValue: capture.initialIcon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch capture.mode {
            case .save:
                HStack {
                    MenuRowLabel("Name", icon: "textformat")
                    TextField("Workspace name", text: $name)
                        .accessibilityLabel("Workspace name")
                        .focused($nameFocused)
                        .measuredMenuRegion("Workspace name")
                }
                .menuRowHeight()
                .padding(.horizontal, 10)
                WorkspaceIconPicker(selection: $icon)
            case .update(_, let name):
                MenuRowLabel(name, icon: capture.initialIcon.symbol)
                    .font(.headline)
                    .help(name)
                    .padding(.horizontal, 10)
            }
            Text("\(selected.count) of \(capture.snapshot.windowCount) windows selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ForEach(capture.snapshot.members) { member in
                appGroup(member)
            }
            Divider()
            Text("On restore · \(outsidePolicy.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 5) {
                Button(action: cancel) { MenuRowLabel("Cancel", icon: "xmark") }
                    .keyboardShortcut(.cancelAction)
                Button { save(name, selected, icon) } label: {
                    MenuRowLabel(capture.mode.action, icon: "checkmark")
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MenuRowStyle(emphasized: true))
                    .disabled(!canSave || selected.isEmpty || needsName)
            }
        }
        .onAppear {
            if case .save = capture.mode { nameFocused = true }
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
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(included) of \(member.windows.count) windows selected")
                }
            }
            .menuRowHeight()
            ForEach(member.windows) { window in
                Toggle(isOn: selection(for: window.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        MenuRowLabel(member.windowLabel(for: window), icon: "macwindow")
                        Text(capture.location(of: window))
                            .padding(.leading, 32)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .popoverProse()
                    }
                }
                .measuredMenuRegion("Window: \(window.order)")
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
