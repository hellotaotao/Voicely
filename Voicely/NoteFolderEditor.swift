//
//  NoteFolderEditor.swift
//  Voicely
//

import SwiftUI

/// Names a folder slot and picks its color.
struct NoteFolderEditor: View {
    let slot: Int
    let isExisting: Bool
    private let savedName: String
    /// Recordings in the folder; removing a non-empty folder asks first.
    let noteCount: Int
    let onSave: (String, Int) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorIndex: Int
    @State private var confirmingRemoval = false
    @FocusState private var nameFocused: Bool

    init(
        slot: Int,
        folder: NoteFolder?,
        noteCount: Int,
        onSave: @escaping (String, Int) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.slot = slot
        self.isExisting = folder != nil
        self.savedName = folder?.name ?? ""
        self.noteCount = noteCount
        self.onSave = onSave
        self.onRemove = onRemove
        _name = State(initialValue: folder?.name ?? "")
        _colorIndex = State(initialValue: folder?.colorIndex ?? NoteFolderPalette.defaultIndex(forSlot: slot))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text(isExisting
                        ? "Short names fit the folder bar best."
                        : "You can have up to \(NoteFolderSlots.all.count) folders. Short names fit the folder bar best.")
                }

                Section("Color") {
                    HStack(spacing: 0) {
                        ForEach(NoteFolderPalette.colors.indices, id: \.self) { index in
                            Button {
                                colorIndex = index
                            } label: {
                                Circle()
                                    .fill(NoteFolderPalette.colors[index])
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if index == colorIndex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if isExisting {
                    Section {
                        Button("Remove Folder", role: .destructive) {
                            if noteCount == 0 {
                                remove()
                            } else {
                                confirmingRemoval = true
                            }
                        }
                        .confirmationDialog(
                            NoteFolderCopy.removalTitle(folderName: savedName),
                            isPresented: $confirmingRemoval,
                            titleVisibility: .visible
                        ) {
                            Button("Remove Folder", role: .destructive, action: remove)
                        } message: {
                            Text(NoteFolderCopy.removalMessage(noteCount: noteCount))
                        }
                    } footer: {
                        Text("Recordings in this folder stay, just outside any folder.")
                    }
                }
            }
            .navigationTitle(isExisting ? "Edit Folder" : "New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { nameFocused = !isExisting }
        }
        .presentationDetents([.medium])
    }

    private func remove() {
        onRemove()
        dismiss()
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, colorIndex)
        dismiss()
    }
}
