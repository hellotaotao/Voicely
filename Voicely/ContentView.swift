//
//  ContentView.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \VoiceNote.timestamp, order: .reverse) private var voiceNotes: [VoiceNote]
    @StateObject private var audioService = AudioRecordingService()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var transcriptionService = TranscriptionService()
    @ObservedObject private var cloudManager = CloudStorageManager.shared
    @EnvironmentObject private var syncMonitor: CloudKitSyncMonitor
    @State private var selectedNoteID: UUID?
    @State private var showingSettings = false
    @State private var didSetupServices = false
    @State private var ownershipPollingTask: Task<Void, Never>?

    private var selectedNote: VoiceNote? {
        guard let selectedNoteID else { return nil }
        return voiceNotes.first { $0.id == selectedNoteID }
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if shouldUseHorizontalLayout(geometry: geometry) {
                    horizontalSplitView(geometry: geometry)
                } else {
                    defaultNavigationView
                }
            }
            .background(Color(.systemGroupedBackground))
        }
        .onAppear(perform: syncInitialSelection)
        .onChange(of: voiceNotes.count) { _, _ in
            syncInitialSelection()
            Task { @MainActor in
                await processPendingTranscriptionsIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task { @MainActor in
                await processPendingTranscriptionsIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelLoadedNotification)) { _ in
            Task { @MainActor in
                await processPendingTranscriptionsIfNeeded()
            }
        }
    }
    
    private func shouldUseHorizontalLayout(geometry: GeometryProxy) -> Bool {
        return geometry.size.width > geometry.size.height
            && UIDevice.current.userInterfaceIdiom == .phone
    }
    
    private func horizontalSplitView(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                compactSplitHeader
                noteLibraryList(usesSplitNavigationSelection: false)
            }
            .frame(width: sidebarWidth(for: geometry))
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(modelManager)
            }
            .task {
                await setupServices()
            }
            
            Divider()
            
            detailPane
        }
    }
    
    private var defaultNavigationView: some View {
        NavigationSplitView {
            noteLibraryList(usesSplitNavigationSelection: true)
            .navigationTitle("Voice Notes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("SettingsButton")
                }

                ToolbarItem(placement: .principal) {
                    if cloudManager.isCloudEnabled {
                        SyncStatusView()
                            .environmentObject(cloudManager)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(modelManager)
            }
            .task {
                await setupServices()
            }
        } detail: {
            detailPane
        }
    }

    private func sidebarWidth(for geometry: GeometryProxy) -> CGFloat {
        min(max(geometry.size.width * 0.36, 300), 400)
    }

    private var compactSplitHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Notes")
                    .font(.title2.weight(.semibold))

                Text(librarySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func noteLibraryList(usesSplitNavigationSelection: Bool) -> some View {
        ZStack(alignment: .bottom) {
            noteList(usesSplitNavigationSelection: usesSplitNavigationSelection)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .contentMargins(.bottom, sidebarRecordingOverlayInset, for: .scrollContent)
            .refreshable {
                await cloudManager.refreshSync()
            }
            
            RecordingControls(
                audioService: audioService,
                transcriptionService: transcriptionService,
                onManageModels: {
                    showingSettings = true
                },
                onRecordingComplete: { note in
                    modelContext.insert(note)
                    selectedNoteID = note.id
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .zIndex(1)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func noteList(usesSplitNavigationSelection: Bool) -> some View {
        if usesSplitNavigationSelection {
            List(selection: $selectedNoteID) {
                noteListContent(usesSplitNavigationSelection: true)
            }
        } else {
            List {
                noteListContent(usesSplitNavigationSelection: false)
            }
        }
    }

    @ViewBuilder
    private func noteListContent(usesSplitNavigationSelection: Bool) -> some View {
        if syncMonitor.syncStatus != .idle && syncMonitor.syncStatus != .success {
            Section {
                SyncStatusBannerCard(
                    description: syncMonitor.statusDescription,
                    tint: syncMonitor.statusColor,
                    showsRetry: {
                        if case .error = syncMonitor.syncStatus {
                            return true
                        }
                        return false
                    }(),
                    retryAction: {
                        Task {
                            await syncMonitor.forceSyncIfNeeded()
                        }
                    }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }

        Section(voiceNotes.isEmpty ? "Get Started" : "Recent Recordings") {
            if voiceNotes.isEmpty {
                EmptyLibraryCard()
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(voiceNotes) { note in
                    noteRow(note: note, usesSplitNavigationSelection: usesSplitNavigationSelection)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if transcriptionService.isLocallyTranscribing(note) {
                                Button {
                                    cancelTranscription(for: note)
                                } label: {
                                    Label("Cancel Transcription", systemImage: "xmark.circle")
                                }
                            }

                            Button(role: .destructive) {
                                deleteNote(note)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete(perform: deleteNotes)
            }
        }
    }

    private func noteRow(note: VoiceNote, usesSplitNavigationSelection: Bool) -> some View {
        let row = VoiceNoteRow(
            note: note,
            transcriptionService: transcriptionService,
            isSelected: selectedNoteID == note.id
        )

        return Group {
            if usesSplitNavigationSelection {
                NavigationLink(value: note.id) {
                    row
                        .foregroundStyle(.primary)
                }
            } else {
                Button {
                    selectedNoteID = note.id
                } label: {
                    row
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var detailPane: some View {
        Group {
            if let selectedNote = selectedNote {
                detailView(selectedNote)
            } else {
                DetailPlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func detailView(_ note: VoiceNote) -> some View {
        VoiceNoteDetailView(note: note, showingSettings: $showingSettings)
            .environmentObject(transcriptionService)
    }

    private var librarySubtitle: String {
        voiceNotes.isEmpty ? "Ready to capture your first recording." : "\(voiceNotes.count) recordings"
    }

    private var sidebarRecordingOverlayInset: CGFloat {
        120
    }

    private func syncInitialSelection() {
        guard !voiceNotes.isEmpty else {
            selectedNoteID = nil
            return
        }

        guard let selectedNoteID,
              voiceNotes.contains(where: { $0.id == selectedNoteID }) else {
            self.selectedNoteID = voiceNotes.first?.id
            return
        }
    }

    private func setupServices() async {
        guard !didSetupServices else { return }
        didSetupServices = true

        guard !AppRuntime.isRunningTests else {
            transcriptionService.setModelManager(modelManager)
            return
        }

        transcriptionService.setModelManager(modelManager)
        await modelManager.fetchModels(includeRemote: false)
        transcriptionService.migrateLegacyOwnershipIfNeeded(notes: voiceNotes)
        startOwnershipPolling()

        // Migrate local files to iCloud if available
        if cloudManager.isCloudEnabled {
            await cloudManager.migrateLocalFilesToCloud()
            await cloudManager.refreshSync()
        }

        // Always preload model on startup to optimize user experience
        if !transcriptionService.isWhisperAvailable() {
            Task {
                let _ = await transcriptionService.loadWhisperModel()
            }
        } else {
            await processPendingTranscriptionsIfNeeded()
        }
    }

    private func processPendingTranscriptionsIfNeeded() async {
        transcriptionService.migrateLegacyOwnershipIfNeeded(notes: voiceNotes)
        let candidates = voiceNotes.filter { !$0.audioFilePath.isEmpty }
        guard !candidates.isEmpty else {
            return
        }

        await transcriptionService.processPendingTranscriptions(notes: candidates)
    }

    private func startOwnershipPolling() {
        guard ownershipPollingTask == nil else { return }

        ownershipPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await processPendingTranscriptionsIfNeeded()
            }
        }
    }

    private func deleteNotes(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                deleteNoteAndAudio(voiceNotes[index])
            }
        }
    }
    
    private func deleteNote(_ note: VoiceNote) {
        withAnimation {
            deleteNoteAndAudio(note)
        }
    }

    private func deleteNoteAndAudio(_ note: VoiceNote) {
        let replacementNote = voiceNotes.first { $0.id != note.id }

        if transcriptionService.isLocallyTranscribing(note) {
            transcriptionService.cancelTranscription(for: note)
        }

        if !note.audioFilePath.isEmpty {
            cloudManager.deleteFile(at: note.audioFilePath)
        }

        if selectedNoteID == note.id {
            selectedNoteID = replacementNote?.id
        }

        modelContext.delete(note)
    }
    
    private func cancelTranscription(for note: VoiceNote) {
        transcriptionService.cancelTranscription(for: note)
    }
}

struct VoiceNoteRow: View {
    let note: VoiceNote
    @ObservedObject var transcriptionService: TranscriptionService
    var isSelected = false

    private var isLocallyTranscribing: Bool {
        transcriptionService.isLocallyTranscribing(note)
    }

    private var isRemoteTranscribing: Bool {
        transcriptionService.isTranscribingOnAnotherDevice(note)
    }

    private var isPending: Bool {
        transcriptionService.shouldShowPendingState(note)
    }

    private var localProgress: Float {
        transcriptionService.localProgress(for: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(note.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                StatusBadge(
                    title: formatDuration(note.duration),
                    systemImage: "clock",
                    tint: .secondary
                )
            }

            if isLocallyTranscribing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(Int(localProgress * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: localProgress)
                        .tint(.accentColor)
                }
            } else if isRemoteTranscribing {
                Text("Transcription in progress on another device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !note.transcription.isEmpty {
                Text(note.transcription)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            } else if isPending {
                Text("Audio saved and waiting for transcription.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Open the note to play back or edit the transcript.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if isLocallyTranscribing {
                StatusBadge(
                    title: "Transcribing here",
                    systemImage: "waveform.badge.magnifyingglass",
                    tint: .accentColor
                )
            } else if isRemoteTranscribing {
                StatusBadge(
                    title: "Another device",
                    systemImage: "desktopcomputer.and.iphone",
                    tint: .blue
                )
            } else if isPending {
                StatusBadge(
                    title: "Transcription pending",
                    systemImage: "clock.arrow.circlepath",
                    tint: .orange
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundShape)
        .overlay(borderShape)
        .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        if let formatted = formatter.string(from: duration), !formatted.isEmpty {
            return formatted
        }
        return "0s"
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.10)
                    : Color(.secondarySystemGroupedBackground)
            )
    }

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(
                isSelected
                    ? Color.accentColor.opacity(0.28)
                    : Color.primary.opacity(0.05),
                lineWidth: 1
            )
    }
}

struct RecordingControls: View {
    @ObservedObject var audioService: AudioRecordingService
    @ObservedObject var transcriptionService: TranscriptionService
    let onManageModels: () -> Void
    let onRecordingComplete: (VoiceNote) -> Void
    @State private var showingModelPicker = false

    private var isModelLoading: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loading || modelManager.modelState == .downloading
            || modelManager.modelState == .prewarming
    }

    private var isModelLoaded: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.isModelLoaded()
    }

    private var modelManager: ModelManager? {
        transcriptionService.modelManager
    }

    private var selectedModelDisplayName: String {
        guard let selectedModel = modelManager?.selectedModel, !selectedModel.isEmpty else {
            return "Small"
        }
        return ModelManager.displayName(for: selectedModel)
    }

    private var selectedModelStatusTitle: String {
        if !audioService.hasPermission {
            return "Mic Off"
        }

        guard let modelManager else {
            return "Manage"
        }

        switch modelManager.modelState {
        case .loaded:
            return "Ready"
        case .loading, .downloading, .prewarming:
            return "Loading"
        case .unloaded:
            return modelManager.isSelectedModelDownloaded() ? "Local" : "Manage"
        }
    }

    private var selectedModelStatusTint: Color {
        if !audioService.hasPermission {
            return .orange
        }

        guard let modelManager else {
            return .secondary
        }

        switch modelManager.modelState {
        case .loaded:
            return .green
        case .loading, .downloading, .prewarming:
            return .orange
        case .unloaded:
            return modelManager.isSelectedModelDownloaded() ? .secondary : .accentColor
        }
    }

    private var quickSelectableModels: [String] {
        guard let modelManager else { return [] }

        return modelManager.localModels.sorted { lhs, rhs in
            ModelManager.displayName(for: lhs).localizedCaseInsensitiveCompare(ModelManager.displayName(for: rhs)) == .orderedAscending
        }
    }

    private var modelPickerMessage: String {
        if quickSelectableModels.isEmpty {
            return "Download a model in Settings to make it available here."
        }

        return "Choose a downloaded model for new transcriptions."
    }

    var body: some View {
        HStack(spacing: 14) {
            waveformRail
            controlsCluster
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(height: 92)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 24, y: 12)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: audioService.isRecording)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: audioService.isPaused)
        .confirmationDialog(
            "Transcription Model",
            isPresented: $showingModelPicker,
            titleVisibility: .visible
        ) {
            if !quickSelectableModels.isEmpty {
                ForEach(quickSelectableModels, id: \.self) { model in
                    Button(modelPickerButtonTitle(for: model)) {
                        selectModel(model)
                    }
                    .disabled(isModelLoading)
                }
            }

            Button("Manage Models…") {
                onManageModels()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(modelPickerMessage)
        }
    }

    private func startRecording() {
        _ = audioService.startRecording()
    }

    private func togglePauseResume() {
        if audioService.isPaused {
            audioService.resumeRecording()
        } else {
            audioService.pauseRecording()
        }
    }

    private func stopRecording() {
        let (filePath, duration) = audioService.stopRecording()

        guard let filePath = filePath else { return }

        let note = VoiceNote(
            title:
                "Voice Note \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))",
            audioFilePath: filePath
        )
        note.duration = duration

        transcriptionService.configureNewNote(note, shouldStartImmediately: isModelLoaded)
        onRecordingComplete(note)

        if isModelLoaded {
            Task {
                await transcriptionService.processPendingTranscriptions(notes: [note])
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var waveformRail: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(audioService.isRecording ? Color.accentColor.opacity(0.08) : Color(.quaternarySystemFill))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
            )
            .overlay {
                Group {
                    if audioService.isRecording {
                        recordingWaveformRailContent
                    } else {
                        modelSelectionRailContent
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
    }

    private var recordingWaveformRailContent: some View {
        HStack(spacing: 12) {
            AudioWaveformView(
                isAnimating: audioService.isRecording && !audioService.isPaused,
                audioService: audioService,
                visualStyle: .active
            )
            .frame(width: 92, height: 24)

            Spacer(minLength: 8)

            Text(formatDuration(audioService.recordingDuration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var modelSelectionRailContent: some View {
        Button {
            showingModelPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription Model")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(selectedModelDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(selectedModelStatusTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedModelStatusTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(selectedModelStatusTint.opacity(0.12), in: Capsule())

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelPickerButtonTitle(for model: String) -> String {
        let displayName = ModelManager.displayName(for: model)
        if modelManager?.selectedModel == model {
            return "✓ \(displayName)"
        }
        return displayName
    }

    private func selectModel(_ model: String) {
        guard let modelManager else { return }

        if modelManager.selectedModel == model && modelManager.isModelLoaded() {
            return
        }

        if modelManager.selectedModel != model {
            modelManager.selectedModel = model
        }

        modelManager.modelState = .unloaded
        modelManager.errorMessage = nil

        Task {
            await modelManager.loadModel(model)
        }
    }

    private var controlsCluster: some View {
        Group {
            if audioService.isRecording {
                HStack(spacing: 12) {
                    secondaryControlSlot
                    primaryActionButton
                }
                .frame(width: 128, alignment: .trailing)
            } else {
                primaryActionButton
            }
        }
    }

    private var secondaryControlSlot: some View {
        VStack(spacing: 6) {
            Button(action: togglePauseResume) {
                Image(systemName: audioService.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(audioService.isPaused ? .green : .orange)
                    .frame(width: 40, height: 40)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(audioService.isPaused ? "Paused" : "Recording")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 68, height: 60, alignment: .center)
    }

    private var primaryActionButton: some View {
        Button(action: audioService.isRecording ? stopRecording : startRecording) {
            Image(systemName: audioService.isRecording ? "stop.fill" : "mic.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(
                        audioService.isRecording
                            ? AnyShapeStyle(Color.red.gradient)
                            : AnyShapeStyle(audioService.hasPermission ? Color.accentColor.gradient : Color.gray.gradient)
                    )
                )
                .shadow(
                    color: audioService.isRecording
                        ? Color.red.opacity(0.24)
                        : audioService.hasPermission ? Color.accentColor.opacity(0.22) : .clear,
                    radius: 10,
                    y: 5
                )
        }
        .buttonStyle(.plain)
        .disabled(!audioService.hasPermission && !audioService.isRecording)
    }
}

struct VoiceNoteDetailView: View {
    let note: VoiceNote
    @Binding var showingSettings: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var transcriptionService: TranscriptionService
    @State private var showLoadModelPrompt = false
    @State private var showTranscriptionFailureAlert = false
    @State private var showingShareSheet = false
    @State private var isEditing = false
    @State private var showingRetranscribeConfirmation = false
    @State private var transcriptionFailureMessage = ""
    @State private var editedTitle = ""
    @State private var editedTranscription = ""
    @StateObject private var audioPlayer = AudioPlayerService()

    private var isModelLoaded: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.isModelLoaded()
    }

    // Monitor model loading state changes
    private var modelLoadingState: ModelState {
        return transcriptionService.modelManager?.modelState ?? .unloaded
    }

    private var selectedModelDisplayName: String? {
        guard let selectedModel = transcriptionService.modelManager?.selectedModel, !selectedModel.isEmpty else {
            return nil
        }
        return ModelManager.displayName(for: selectedModel)
    }

    private var isLocallyTranscribing: Bool {
        transcriptionService.isLocallyTranscribing(note)
    }

    private var isRemoteTranscribing: Bool {
        transcriptionService.isTranscribingOnAnotherDevice(note)
    }

    private var shouldShowTakeOverAction: Bool {
        note.transcription.isEmpty && isRemoteTranscribing
    }

    private var shouldShowPendingState: Bool {
        transcriptionService.shouldShowPendingState(note)
    }

    private var localTranscriptionProgress: Float {
        transcriptionService.localProgress(for: note)
    }

    private var usesCompactDetailLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact
    }

    private var transcriptionSummaryText: String? {
        guard !note.transcription.isEmpty else {
            return note.lastTranscriptionDuration > 0
                ? "Last run: \(transcriptionService.formatTranscriptionDuration(note.lastTranscriptionDuration))."
                : nil
        }

        var parts: [String] = []

        if note.lastTranscriptionDuration > 0 {
            var lastRun = "Last run: \(transcriptionService.formatTranscriptionDuration(note.lastTranscriptionDuration))"
            if let modelName = note.transcriptionModelDisplayName {
                lastRun += " using \(modelName)"
            }
            parts.append(lastRun + ".")
        } else if let modelName = note.transcriptionModelDisplayName {
            parts.append("Transcribed with \(modelName).")
        }

        if note.transcriptionModelDisplayName == nil {
            parts.append("Model not recorded for this transcript.")
        }

        if let selectedModelDisplayName,
           note.transcriptionModelDisplayName != selectedModelDisplayName {
            parts.append("Selected now: \(selectedModelDisplayName).")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var retranscribeConfirmationMessage: String {
        let nextModel = selectedModelDisplayName ?? "the currently selected model"

        if let currentModel = note.transcriptionModelDisplayName,
           currentModel != nextModel {
            return "This note currently uses \(currentModel). Re-transcribing will use \(nextModel) and replace the current transcript."
        }

        if let currentModel = note.transcriptionModelDisplayName {
            return "This will run transcription again using \(currentModel) and replace the current transcript."
        }

        return "This will run transcription again using \(nextModel) and replace the current transcript."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: usesCompactDetailLayout ? 16 : 20) {
                detailHeaderCard

                if !note.audioFilePath.isEmpty {
                    audioPlayerCard
                }

                transcriptionCard
            }
            .padding(usesCompactDetailLayout ? 16 : 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [shareableTranscriptionText()])
        }
        .onChange(of: modelLoadingState) { oldValue, newValue in
            if newValue == .loaded {
                Task { @MainActor in
                    await transcriptionService.processPendingTranscriptions(notes: [note])
                }
            }
        }
        .alert("Model Not Loaded", isPresented: $showLoadModelPrompt) {
            Button("Open Settings") { showingSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please load a model in Settings first to transcribe this recording.")
        }
        .alert("Transcription Failed", isPresented: $showTranscriptionFailureAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transcriptionFailureMessage)
        }
        .confirmationDialog(
            "Re-transcribe this note?",
            isPresented: $showingRetranscribeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-transcribe") {
                requestTranscription(force: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(retranscribeConfirmationMessage)
        }
        .onAppear {
            loadAudioFile()
            editedTitle = note.title
            editedTranscription = note.transcription
        }
        .onChange(of: note.id) { _, _ in
            if isEditing { isEditing = false }
            loadAudioFile()
            editedTitle = note.title
            editedTranscription = note.transcription
        }
    }

    private var detailHeaderCard: some View {
        SectionCard(contentPadding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    headerIcon

                    headerTitleContent

                    Spacer(minLength: 8)

                    editButton
                }

                WrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    headerStatusBadges
                }
            }
        }
    }

    private var audioPlayerCard: some View {
        SectionCard(contentPadding: 14) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    timeProgressRow
                    playbackRateMenu
                }

                HStack(spacing: 14) {
                    Spacer()

                    transportButton(systemImage: "gobackward.5", size: 38) {
                        audioPlayer.seekBackward()
                    }

                    Button(action: { audioPlayer.togglePlayPause() }) {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(Color.accentColor.gradient))
                            .shadow(color: Color.accentColor.opacity(0.24), radius: 10, y: 5)
                    }
                    .buttonStyle(.plain)

                    transportButton(systemImage: "goforward.5", size: 38) {
                        audioPlayer.seekForward()
                    }

                    Spacer()
                }

                if audioPlayer.isPreparingAudio {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(audioPlayer.playbackStatusMessage ?? "Preparing audio...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let playbackStatusMessage = audioPlayer.playbackStatusMessage {
                    Text(playbackStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var playbackRateMenu: some View {
        Menu {
            Picker("Speed", selection: $audioPlayer.playbackRate) {
                Text("0.5x").tag(Float(0.5))
                Text("0.75x").tag(Float(0.75))
                Text("1x").tag(Float(1.0))
                Text("1.25x").tag(Float(1.25))
                Text("1.5x").tag(Float(1.5))
                Text("2x").tag(Float(2.0))
            }
            .onChange(of: audioPlayer.playbackRate) { _, newRate in
                audioPlayer.setPlaybackRate(newRate)
            }
        } label: {
            Text(String(format: "%.2gx", audioPlayer.playbackRate))
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private var transcriptionCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 16) {
                if usesCompactDetailLayout {
                    VStack(alignment: .leading, spacing: 12) {
                        transcriptionHeaderContent
                        compactTranscriptionActions
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        transcriptionHeaderContent

                        Spacer()

                        regularTranscriptionActions
                    }
                }

                Group {
                    if isLocallyTranscribing {
                        transcriptionProgressContent
                    } else if isRemoteTranscribing {
                        remoteTranscriptionContent
                    } else if !note.transcription.isEmpty {
                        transcriptionTextContent
                    } else if shouldShowPendingState {
                        pendingTranscriptionContent
                    } else {
                        emptyTranscriptionContent
                    }
                }
            }
        }
    }

    private var regularTranscriptionActions: some View {
        HStack(spacing: 10) {
            if !note.transcription.isEmpty {
                copyButton
                shareButton
            }

            if shouldShowTakeOverAction {
                takeOverButton
            } else if note.transcription.isEmpty {
                transcribeButton
            } else {
                retranscribeButton
            }
        }
    }

    private var compactTranscriptionActions: some View {
        WrappingFlowLayout(horizontalSpacing: 10, verticalSpacing: 10) {
            if !note.transcription.isEmpty {
                copyButton
                shareButton
            }

            if shouldShowTakeOverAction {
                takeOverButton
            } else if note.transcription.isEmpty {
                transcribeButton
            } else {
                retranscribeButton
            }
        }
    }

    private var transcriptionHeaderContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcription")
                .font(.headline)

            if let transcriptionSummaryText {
                Text(transcriptionSummaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var copyButton: some View {
        Button(action: copyTranscription) {
            Image(systemName: "square.on.square")
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var shareButton: some View {
        Button(action: shareTranscription) {
            Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var takeOverButton: some View {
        Button(action: { requestTranscription(takeOver: true) }) {
            Label("Take over on this device", systemImage: "arrow.triangle.branch")
        }
        .buttonStyle(.borderedProminent)
        .disabled(note.audioFilePath.isEmpty || isLocallyTranscribing)
        .help("Claims the current transcription on this device and lets the other device finish without saving.")
        .fixedSize(horizontal: true, vertical: true)
    }

    private var transcribeButton: some View {
        Button(action: { requestTranscription() }) {
            Label("Transcribe", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(note.audioFilePath.isEmpty || isLocallyTranscribing || isRemoteTranscribing)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var retranscribeButton: some View {
        Button(action: { showingRetranscribeConfirmation = true }) {
            Label("Re-transcribe", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .help("Runs transcription again using the model currently selected in Settings.")
        .disabled(note.audioFilePath.isEmpty || isLocallyTranscribing || isRemoteTranscribing)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var transcriptionProgressContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProgressView()
                Text("Transcribing audio…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(localTranscriptionProgress * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: localTranscriptionProgress)
                .tint(.accentColor)

            Button(role: .cancel, action: cancelCurrentTranscription) {
                Label("Cancel Transcription", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    private var remoteTranscriptionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusBadge(
                title: "Transcribing on another device",
                systemImage: "desktopcomputer.and.iphone",
                tint: .blue
            )

            Text("This recording is currently being transcribed elsewhere. The transcript will appear here after sync finishes.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptionTextContent: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedTranscription)
                    .font(.body)
                    .frame(minHeight: 240)
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Text(note.transcription)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pendingTranscriptionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusBadge(
                title: "Waiting for transcription",
                systemImage: "clock.arrow.circlepath",
                tint: .orange
            )

            Text("This recording is waiting for an eligible device to start transcription.")
                .font(.body)
                .foregroundStyle(.secondary)

            Button(action: { requestTranscription() }) {
                Label("Transcribe Now", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyTranscriptionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBadge(
                title: "No transcript yet",
                systemImage: "text.badge.xmark",
                tint: .secondary
            )

            Text("Recordings without transcription can still be played back, renamed, and shared later.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func loadAudioFile() {
        if !note.audioFilePath.isEmpty {
            audioPlayer.loadAudio(from: note.audioFilePath, expectedDuration: note.duration)
        }
    }

    private var headerIcon: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 42, height: 42)

            Image(systemName: note.transcription.isEmpty ? "waveform.circle.fill" : "text.quote")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var headerTitleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Note title", text: $editedTitle)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)

                    Divider()

                    timestampText
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    timestampText
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timestampText: some View {
        Text(
            note.timestamp,
            format: Date.FormatStyle(date: .abbreviated, time: .shortened)
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var editButton: some View {
        Button(action: toggleEdit) {
            Text(isEditing ? "Done" : "Edit")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var headerStatusBadges: some View {
        StatusBadge(
            title: formatDuration(note.duration),
            systemImage: "clock",
            tint: .secondary
        )

        if isLocallyTranscribing {
            StatusBadge(
                title: "Processing",
                systemImage: "waveform.badge.magnifyingglass",
                tint: Color.accentColor
            )
        } else if isRemoteTranscribing {
            StatusBadge(
                title: "Another device",
                systemImage: "desktopcomputer.and.iphone",
                tint: .blue
            )
        } else if shouldShowPendingState {
            StatusBadge(
                title: "Pending",
                systemImage: "clock.arrow.circlepath",
                tint: .orange
            )
        } else if !note.transcription.isEmpty {
            StatusBadge(
                title: "Transcript",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            TranscriptionModelBadge(note: note)
        }
    }

    private var timeProgressRow: some View {
        HStack(spacing: 10) {
            Text(formatTime(audioPlayer.currentTime))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            ProgressView(value: audioPlayer.currentTime, total: max(audioPlayer.duration, 1))
                .tint(.accentColor)

            Text(formatTime(audioPlayer.duration))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func toggleEdit() {
        if isEditing {
            // Save changes
            note.title = editedTitle
            note.transcription = editedTranscription
            if editedTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note.transcriptionModelIdentifier = nil
            }
        } else {
            // Enter edit mode
            editedTitle = note.title
            editedTranscription = note.transcription
        }
        isEditing.toggle()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func copyTranscription() {
        UIPasteboard.general.string = shareableTranscriptionText()
    }

    private func shareTranscription() {
        showingShareSheet = true
    }

    private func requestTranscription(force: Bool = false, takeOver: Bool = false) {
        guard !note.audioFilePath.isEmpty else { return }

        guard isModelLoaded else {
            showLoadModelPrompt = true
            return
        }

        Task { @MainActor in
            let startedWithEmptyTranscript = note.transcription.isEmpty
            let didStart = await transcriptionService.requestTranscription(
                for: note,
                force: force,
                takeOver: takeOver
            )
            if didStart, !isEditing {
                editedTranscription = note.transcription
            }
            if didStart,
               startedWithEmptyTranscript,
               note.transcription.isEmpty,
               note.transcriptionState == .queued,
               !transcriptionService.wasTranscriptionCancelled() {
                transcriptionFailureMessage = "No usable transcript was produced for this recording. You can try again or choose a different model in Settings."
                showTranscriptionFailureAlert = true
            }
        }
    }

    private func shareableTranscriptionText() -> String {
        guard note.lastTranscriptionDuration > 0 else {
            return note.transcription
        }

        return transcriptionService.annotatedText(
            text: note.transcription,
            duration: note.lastTranscriptionDuration
        )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: duration) ?? "0 seconds"
    }
    
    private func cancelCurrentTranscription() {
        transcriptionService.cancelTranscription(for: note)
    }

    private func transportButton(systemImage: String, size: CGFloat, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct SectionCard<Content: View>: View {
    private let backgroundColor: Color
    private let borderColor: Color
    private let contentPadding: CGFloat
    private let content: Content

    init(
        backgroundColor: Color = Color(.secondarySystemGroupedBackground),
        borderColor: Color = Color.primary.opacity(0.05),
        contentPadding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

private struct WrappingFlowLayout: Layout {
    struct Item {
        let index: Int
        let frame: CGRect
    }

    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> [Item] {
        []
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [Item]
    ) -> CGSize {
        cache = frames(for: subviews, maxWidth: proposal.width ?? .greatestFiniteMagnitude)
        let width = cache.map(\.frame.maxX).max() ?? 0
        let height = cache.map(\.frame.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [Item]
    ) {
        cache = frames(for: subviews, maxWidth: bounds.width)

        for item in cache {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                proposal: ProposedViewSize(item.frame.size)
            )
        }
    }

    private func frames(for subviews: Subviews, maxWidth: CGFloat) -> [Item] {
        let availableWidth = max(maxWidth, 0)
        var items: [Item] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)

            if currentX > 0 && currentX + size.width > availableWidth {
                currentX = 0
                currentY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }

            let frame = CGRect(origin: CGPoint(x: currentX, y: currentY), size: size)
            items.append(Item(index: index, frame: frame))

            currentX += size.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, size.height)
        }

        return items
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    private var displayTitle: String {
        title.isEmpty ? "0s" : title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.medium))

            Text(displayTitle)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct TranscriptionModelBadge: View {
    let note: VoiceNote

    private var title: String {
        note.transcriptionModelDisplayName ?? "Model Unknown"
    }

    private var systemImage: String {
        note.transcriptionModelDisplayName == nil ? "questionmark.circle" : "cpu"
    }

    private var tint: Color {
        note.transcriptionModelDisplayName == nil ? .orange : .blue
    }

    var body: some View {
        StatusBadge(title: title, systemImage: systemImage, tint: tint)
    }
}

private struct RecorderStatusChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct SyncStatusBannerCard: View {
    let description: String
    let tint: Color
    let showsRetry: Bool
    let retryAction: () -> Void

    var body: some View {
        SectionCard(
            backgroundColor: tint.opacity(0.08),
            borderColor: tint.opacity(0.18)
        ) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Status")
                        .font(.subheadline.weight(.medium))

                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showsRetry {
                    Button("Retry", action: retryAction)
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct EmptyLibraryCard: View {
    var body: some View {
        SectionCard {
            ContentUnavailableView(
                "No Recordings Yet",
                systemImage: "mic.circle",
                description: Text("Use the record control below to create your first voice note.")
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct DetailPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Recording",
            systemImage: "waveform.circle",
            description: Text("Choose a note from the library or start a new recording.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AudioWaveformView: View {
    enum VisualStyle {
        case active
        case placeholder
    }

    let isAnimating: Bool
    @ObservedObject var audioService: AudioRecordingService
    var visualStyle: VisualStyle = .active
    @State private var waveHeights: [CGFloat] = Array(repeating: 0.2, count: 18)

    var body: some View {
        if isAnimating {
            TimelineView(.animation(minimumInterval: 0.05)) { timeline in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<18, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(barColor)
                            .frame(width: barWidth)
                            .scaleEffect(y: waveHeights[index], anchor: .center)
                            .animation(.easeInOut(duration: 0.05), value: waveHeights[index])
                    }
                }
                .frame(height: 24)
                .onAppear {
                    updateWaveHeights()
                }
                .onChange(of: timeline.date) { _, _ in
                    updateWaveHeights()
                }
            }
        } else {
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<18, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor)
                        .frame(width: barWidth)
                        .scaleEffect(y: restingHeight(at: index), anchor: .center)
                }
            }
            .frame(height: 24)
        }
    }

    private func updateWaveHeights() {
        var newHeights = waveHeights
        newHeights.removeFirst()
        let base = CGFloat(max(0, min(1, audioService.audioLevel)))
        let adjusted = pow(base, 0.6)
        let variation = CGFloat.random(in: 0.9...1.1)
        let level = adjusted * variation
        let minH: CGFloat = 0.2
        let maxH: CGFloat = 1.35
        let newH = minH + (maxH - minH) * level
        newHeights.append(max(minH, min(maxH, newH)))
        waveHeights = newHeights
    }

    private var barColor: Color {
        switch visualStyle {
        case .active:
            return Color.accentColor
        case .placeholder:
            return Color.accentColor.opacity(0.26)
        }
    }

    private var barWidth: CGFloat {
        switch visualStyle {
        case .active:
            return 3
        case .placeholder:
            return 2.8
        }
    }

    private func restingHeight(at index: Int) -> CGFloat {
        let placeholderHeights: [CGFloat] = [
            0.24, 0.34, 0.2, 0.3, 0.18, 0.28, 0.22, 0.36, 0.2,
            0.3, 0.18, 0.26, 0.22, 0.32, 0.2, 0.28, 0.18, 0.24
        ]

        switch visualStyle {
        case .active:
            return 0.26
        case .placeholder:
            return placeholderHeights[index]
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ShareSheet>)
        -> UIActivityViewController
    {
        let controller = UIActivityViewController(
            activityItems: activityItems, applicationActivities: applicationActivities)

        // For iPad and Mac Catalyst, we need to configure the popover presentation
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView()
            popover.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: UIViewControllerRepresentableContext<ShareSheet>
    ) {}
}

#Preview {
    ContentView()
        .modelContainer(for: VoiceNote.self, inMemory: true)
}
