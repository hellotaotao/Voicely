//
//  NoteFolderBar.swift
//  Voicely
//
//  The row above the note list: All, Unfiled and the four folder slots.
//  Tapping one filters the list; dropping a dragged note on one files it.
//

import SwiftUI

struct NoteFolderBar: View {
    let folders: NoteFolderSet
    @Binding var filter: NoteFolderFilter
    /// Returns whether the dropped note was moved.
    let onDropNote: (UUID, Int) -> Bool
    let onEditSlot: (Int) -> Void
    let onRemoveSlot: (Int) -> Void

    @State private var targetedItem: NoteFolderFilter?
    @State private var dropCount = 0

    private var items: [NoteFolderFilter] {
        [.all, .unfiled] + NoteFolderSlots.all.map { .folder($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(items, id: \.self) { item in
                itemView(item)
                    .frame(maxWidth: .infinity)
                    .zIndex(targetedItem == item ? 1 : 0)
            }
        }
        .sensoryFeedback(.selection, trigger: targetedItem) { _, newValue in newValue != nil }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(VoicelyTheme.groupedBackground)
        .sensoryFeedback(.success, trigger: dropCount)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.folderBar)
    }

    @ViewBuilder
    private func itemView(_ item: NoteFolderFilter) -> some View {
        let isSelected = filter == item
        let isTargeted = targetedItem == item
        let button = Button {
            if case .folder(let slot) = item, folders.folder(forSlot: slot) == nil {
                onEditSlot(slot)
            } else {
                filter = item
            }
        } label: {
            // While a dragged note hovers here, the whole item grows, fills with the
            // folder colour and gets an outline, so it still reads as "targeted" when
            // the drag preview and the finger cover most of the icon.
            VStack(spacing: 3) {
                icon(for: item, isSelected: isSelected || isTargeted)
                Text(label(for: item))
                    .font(.caption2.weight(isSelected || isTargeted ? .semibold : .regular))
                    .foregroundStyle(isTargeted ? Color.white : (isSelected ? Color.primary : Color.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted ? tint(for: item).opacity(0.85) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isTargeted ? tint(for: item) : Color.clear, lineWidth: 2)
            )
            .shadow(color: isTargeted ? tint(for: item).opacity(0.45) : .clear, radius: 8, y: 2)
            .scaleEffect(isTargeted ? 1.35 : 1)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.folderBarItem)

        switch item {
        case .all:
            button
        case .unfiled:
            button.dropDestination(for: String.self) { payloads, _ in
                drop(payloads, intoSlot: NoteFolderSlots.unfiled)
            } isTargeted: { setTargeted($0, item) }
        case .folder(let slot):
            if folders.folder(forSlot: slot) != nil {
                button
                    .dropDestination(for: String.self) { payloads, _ in
                        drop(payloads, intoSlot: slot)
                    } isTargeted: { setTargeted($0, item) }
                    .contextMenu {
                        Button {
                            onEditSlot(slot)
                        } label: {
                            Label("Edit Folder…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            onRemoveSlot(slot)
                        } label: {
                            Label("Remove Folder", systemImage: "folder.badge.minus")
                        }
                    }
            } else {
                button
            }
        }
    }

    private func drop(_ payloads: [String], intoSlot slot: Int) -> Bool {
        let moved = payloads.compactMap(NoteDragPayload.noteID(from:)).filter { onDropNote($0, slot) }
        guard !moved.isEmpty else { return false }
        dropCount += 1
        return true
    }

    private func setTargeted(_ targeted: Bool, _ item: NoteFolderFilter) {
        if targeted {
            targetedItem = item
        } else if targetedItem == item {
            targetedItem = nil
        }
    }

    @ViewBuilder
    private func icon(for item: NoteFolderFilter, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        switch item {
        case .all, .unfiled:
            Image(systemName: item == .all ? "tray.full.fill" : "tray")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : VoicelyTheme.accent)
                .frame(width: 34, height: 30)
                .background(shape.fill(isSelected ? VoicelyTheme.accent : VoicelyTheme.surface))
        case .folder(let slot):
            if let color = folders.color(forSlot: slot) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : color)
                    .frame(width: 34, height: 30)
                    .background(shape.fill(isSelected ? color : color.opacity(0.16)))
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, height: 30)
                    .background(shape.strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
    }

    private func label(for item: NoteFolderFilter) -> String {
        switch item {
        case .all: return "All"
        case .unfiled: return "Unfiled"
        case .folder(let slot): return folders.folder(forSlot: slot)?.name ?? "New"
        }
    }

    private func tint(for item: NoteFolderFilter) -> Color {
        if case .folder(let slot) = item, let color = folders.color(forSlot: slot) { return color }
        return VoicelyTheme.accent
    }

    private func accessibilityLabel(for item: NoteFolderFilter) -> String {
        switch item {
        case .all: return "All recordings"
        case .unfiled: return "Unfiled recordings"
        case .folder(let slot):
            if let folder = folders.folder(forSlot: slot) { return "Folder \(folder.name)" }
            return "New folder"
        }
    }
}

/// A shrunken copy of the note's row that follows the pointer while a note is
/// dragged. The default preview is the whole translucent row, which covers the
/// folder bar and hides the highlight on the folder under it; a bare chip is
/// too small to read as the note that was picked up.
struct NoteDragPreview: View {
    let title: String
    let timestamp: Date
    let duration: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let duration {
                    Label(
                        Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond)),
                        systemImage: "waveform"
                    )
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
                }
                Text(timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VoicelyTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VoicelyTheme.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Records which note a drag lifted, from the moment the drag starts until it
/// ends or is cancelled. Drag-session updates need iOS 27 / macOS 26; earlier
/// systems drag the same way, just without the in-list mark.
struct NoteDragSourceTracking: ViewModifier {
    let noteID: UUID
    @Binding var draggingNoteID: UUID?

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.onDragSessionUpdated { session in
                switch session.phase {
                case .initial, .active:
                    if draggingNoteID != noteID { draggingNoteID = noteID }
                default:
                    if draggingNoteID == noteID { draggingNoteID = nil }
                }
            }
        } else {
            content
        }
    }
}
