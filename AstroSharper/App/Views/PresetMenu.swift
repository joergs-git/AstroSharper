// Toolbar dropdown for picking, saving and managing presets.
//
// Built-in presets are grouped by target with a leading SF Symbol; user
// presets follow underneath. "Save as New…" sheet captures a name + target,
// "Update Current" snapshots the current settings into the active preset
// (only for user presets — built-ins are read-only).
import SwiftUI

struct PresetMenu: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var presets = PresetManager.shared
    @State private var showSaveSheet = false
    @State private var newName: String = ""
    @State private var newTarget: PresetTarget = .sun
    @State private var newNotes: String = ""

    var body: some View {
        Menu {
            // Built-ins, grouped by target.
            ForEach(PresetTarget.allCases) { target in
                let group = presets.builtIn.filter { $0.target == target }
                if !group.isEmpty {
                    Section(header: Label(target.rawValue, systemImage: target.icon)) {
                        ForEach(group) { p in
                            Button {
                                app.applyPreset(p)
                            } label: {
                                HStack {
                                    if p.id == presets.activeID { Image(systemName: "checkmark") }
                                    Text(p.name)
                                }
                            }
                        }
                    }
                }
            }

            if !presets.user.isEmpty {
                Divider()
                Section("My Presets") {
                    ForEach(presets.user) { p in
                        Button {
                            app.applyPreset(p)
                        } label: {
                            HStack {
                                if p.id == presets.activeID { Image(systemName: "checkmark") }
                                Image(systemName: p.target.icon)
                                Text(p.name)
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Save as New Preset…") {
                newName = ""
                newTarget = .sun
                newNotes = ""
                showSaveSheet = true
            }
            Button("Update Current Preset") { app.updateActivePreset() }
                .disabled(activeIsBuiltInOrNil)
            Divider()
            Button("Sync with iCloud") { presets.forceSync() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(currentPresetLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 200)
        .help("Apply a preset, save current settings as a preset, or sync with iCloud.")
        .sheet(isPresented: $showSaveSheet) {
            SavePresetSheet(
                name: $newName,
                target: $newTarget,
                notes: $newNotes,
                onCancel: { showSaveSheet = false },
                onSave: {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    app.saveCurrentAsPreset(name: trimmed, target: newTarget, notes: newNotes)
                    showSaveSheet = false
                }
            )
        }
    }

    private var currentPresetLabel: String {
        if let id = presets.activeID, let p = presets.preset(withID: id) { return p.name }
        return "No Preset"
    }

    private var activeIsBuiltInOrNil: Bool {
        guard let id = presets.activeID, let p = presets.preset(withID: id) else { return true }
        return p.isBuiltIn
    }
}

// MARK: - Save sheet

private struct SavePresetSheet: View {
    @Binding var name: String
    @Binding var target: PresetTarget
    @Binding var notes: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Target", selection: $target) {
                    ForEach(PresetTarget.allCases) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
