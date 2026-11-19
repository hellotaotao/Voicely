import SwiftUI

struct SpeakerNameEditor: View {
    let speakerIDs: [Int]
    let onSave: ([Int: String]) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [Int: String]
    @State private var saveError: String?

    init(speakers: SpeakerTranscript, onSave: @escaping ([Int: String]) throws -> Void) {
        let ids = speakers.speakerIDs
        speakerIDs = ids
        self.onSave = onSave
        _names = State(initialValue: ids.reduce(into: [:]) { $0[$1] = speakers.customName(for: $1) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(speakerIDs, id: \.self) { id in
                        let label = String(localized: "Speaker \(id)")
                        LabeledContent {
                            TextField("Name", text: Binding(
                                get: { names[id, default: ""] },
                                set: { names[id] = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .accessibilityLabel(Text(label))
                            .accessibilityIdentifier("SpeakerName-\(id)")
                        } label: {
                            Text(label)
                        }
                    }
                } footer: {
                    Text("Leave a name blank to use the default label.")
                }
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Speaker Names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            try onSave(names)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
