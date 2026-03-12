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
    @Query(sort: \VoiceNote.timestamp, order: .reverse) private var voiceNotes: [VoiceNote]
    @StateObject private var audioService = AudioRecordingService()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var transcriptionService = TranscriptionService()
    @StateObject private var cloudManager = CloudStorageManager.shared
    @EnvironmentObject private var syncMonitor: CloudKitSyncMonitor
    @State private var selectedNote: VoiceNote?
    @State private var showingSettings = false
    @State private var didSetupServices = false

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
                noteLibraryList(allowsNavigation: false)
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
            noteLibraryList(allowsNavigation: true)
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

    private func noteLibraryList(allowsNavigation: Bool) -> some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    LibrarySummaryCard(
                        title: "Your Library",
                        subtitle: librarySubtitle,
                        noteCount: voiceNotes.count,
                        isCloudEnabled: cloudManager.isCloudEnabled
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

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
                            noteRow(note: note, allowsNavigation: allowsNavigation)
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    if note.isTranscribing {
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
                onRecordingComplete: { note in
                    modelContext.insert(note)
                    selectedNote = note
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .zIndex(1)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func noteRow(note: VoiceNote, allowsNavigation: Bool) -> some View {
        if allowsNavigation {
            NavigationLink(
                destination: detailView(note)
            ) {
                VoiceNoteRow(note: note, isSelected: selectedNote?.id == note.id)
            }
            .simultaneousGesture(TapGesture().onEnded {
                selectedNote = note
            })
        } else {
            Button {
                selectedNote = note
            } label: {
                VoiceNoteRow(note: note, isSelected: selectedNote?.id == note.id)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
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
        VoiceNoteDetailView(note: note)
            .environmentObject(transcriptionService)
    }

    private var librarySubtitle: String {
        voiceNotes.isEmpty ? "Ready to capture your first recording." : "\(voiceNotes.count) recordings"
    }

    private var sidebarRecordingOverlayInset: CGFloat {
        120
    }

    private func syncInitialSelection() {
        guard selectedNote == nil else { return }
        selectedNote = voiceNotes.first
    }

    private func setupServices() async {
        guard !didSetupServices else { return }
        didSetupServices = true

        transcriptionService.setModelManager(modelManager)
        await modelManager.fetchModels(includeRemote: false)
        recoverInterruptedTranscriptions()

        // Migrate local files to iCloud if available
        if cloudManager.isCloudEnabled {
            await cloudManager.migrateLocalFilesToCloud()
            await cloudManager.refreshSync()
        }

        // Add model loading notification observer
        NotificationCenter.default.addObserver(
            forName: .modelLoadedNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [self] in
                await self.processPendingTranscriptionsIfNeeded()
            }
        }

        // Always preload model on startup to optimize user experience
        if !transcriptionService.isWhisperAvailable() {
            Task {
                let _ = await transcriptionService.loadWhisperModel()
            }
        }
    }

    private func processPendingTranscriptionsIfNeeded() async {
        // Find all notes pending transcription
        let pendingNotes = voiceNotes.filter { $0.pendingTranscription }
        if !pendingNotes.isEmpty {
            print("Found \(pendingNotes.count) pending transcriptions to process")
            await transcriptionService.processPendingTranscriptions(notes: pendingNotes)
        }
    }

    private func recoverInterruptedTranscriptions() {
        let interruptedNotes = voiceNotes.filter { $0.isTranscribing }
        guard !interruptedNotes.isEmpty else { return }

        print("Recovering \(interruptedNotes.count) interrupted transcriptions")
        for note in interruptedNotes {
            note.isTranscribing = false
            note.transcriptionProgress = 0.0
            if note.transcription.isEmpty {
                note.pendingTranscription = true
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

        if note.isTranscribing {
            transcriptionService.cancelTranscription()
            note.isTranscribing = false
            note.transcriptionProgress = 0.0
            note.pendingTranscription = false
        }

        if !note.audioFilePath.isEmpty {
            cloudManager.deleteFile(at: note.audioFilePath)
        }

        if selectedNote?.id == note.id {
            selectedNote = replacementNote
        }

        modelContext.delete(note)
    }
    
    private func cancelTranscription(for note: VoiceNote) {
        transcriptionService.cancelTranscription()
        note.isTranscribing = false
        note.transcriptionProgress = 0.0
        note.pendingTranscription = true
    }
}

struct VoiceNoteRow: View {
    let note: VoiceNote
    var isSelected = false

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

            if note.isTranscribing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(Int(note.transcriptionProgress * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: note.transcriptionProgress)
                        .tint(.accentColor)
                }
            } else if !note.transcription.isEmpty {
                Text(note.transcription)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            } else if note.pendingTranscription {
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

            if note.pendingTranscription {
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
        return formatter.string(from: duration) ?? "0s"
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
    let onRecordingComplete: (VoiceNote) -> Void

    private var isModelLoading: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loading || modelManager.modelState == .downloading
            || modelManager.modelState == .prewarming
    }

    private var isModelLoaded: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loaded
    }

    private var modelLoadingMessage: String {
        guard let modelManager = transcriptionService.modelManager else {
            return "Queue"
        }
        switch modelManager.modelState {
        case .loading:
            return "Loading"
        case .downloading:
            return "Loading"
        case .prewarming:
            return "Loading"
        case .unloaded:
            if modelManager.isSelectedModelDownloaded() {
                return "Idle"
            } else {
                return "Queue"
            }
        case .loaded:
            return "Ready"
        }
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

        // Check if model is loaded
        if isModelLoaded {
            note.isTranscribing = true

            onRecordingComplete(note)

            Task {
                let result = await transcriptionService.transcribeAudio(filePath: filePath) {
                    progress in
                    Task { @MainActor in
                        note.transcriptionProgress = progress
                    }
                }

                await MainActor.run {
                    if let result = result {
                        note.transcription = result.text
                        note.lastTranscriptionDuration = result.duration
                        note.pendingTranscription = false
                    } else {
                        note.transcription = ""
                        note.lastTranscriptionDuration = 0
                        note.pendingTranscription = true
                    }
                    note.isTranscribing = false
                    note.transcriptionProgress = 0.0
                }
            }
        } else {
            // If model not loaded, save note without transcription
            note.isTranscribing = false
            note.transcription = ""
            note.pendingTranscription = true

            onRecordingComplete(note)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var recorderStatusBadge: some View {
        Group {
            if !audioService.hasPermission {
                RecorderStatusChip(title: "Mic Off", systemImage: "mic.slash", tint: .orange)
            } else if isModelLoaded {
                RecorderStatusChip(
                    title: "Ready",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            } else if isModelLoading {
                RecorderStatusChip(
                    title: "Loading",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .orange
                )
            } else {
                RecorderStatusChip(
                    title: modelLoadingMessage,
                    systemImage: modelLoadingMessage == "Idle" ? "pause.circle.fill" : "clock.arrow.circlepath",
                    tint: .secondary
                )
            }
        }
    }

    private var waveformRail: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(audioService.isRecording ? Color.accentColor.opacity(0.08) : Color(.quaternarySystemFill))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
            )
            .overlay {
                HStack(spacing: 12) {
                    AudioWaveformView(
                        isAnimating: audioService.isRecording && !audioService.isPaused,
                        audioService: audioService,
                        visualStyle: audioService.isRecording ? .active : .placeholder
                    )
                    .frame(width: 92, height: 24)

                    Spacer(minLength: 8)

                    Text(formatDuration(audioService.recordingDuration))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .opacity(audioService.isRecording ? 1 : 0)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
    }

    private var controlsCluster: some View {
        HStack(spacing: 12) {
            secondaryControlSlot
            primaryActionButton
        }
        .frame(width: 128, alignment: .trailing)
    }

    private var secondaryControlSlot: some View {
        VStack(spacing: 6) {
            if audioService.isRecording {
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
            } else {
                recorderStatusBadge
            }
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
    @EnvironmentObject var transcriptionService: TranscriptionService
    @State private var isTranscribing = false
    @State private var showLoadModelPrompt = false
    @State private var showingShareSheet = false
    @State private var isEditing = false
    @State private var editedTitle = ""
    @State private var editedTranscription = ""
    @StateObject private var audioPlayer = AudioPlayerService()

    private var isModelLoaded: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loaded
    }

    // Monitor model loading state changes
    private var modelLoadingState: ModelState {
        return transcriptionService.modelManager?.modelState ?? .unloaded
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeaderCard

                if !note.audioFilePath.isEmpty {
                    audioPlayerCard
                }

                transcriptionCard
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [shareableTranscriptionText()])
        }
        .onChange(of: modelLoadingState) { oldValue, newValue in
            if newValue == .loaded && note.pendingTranscription && !note.isTranscribing
                && !transcriptionService.isTranscribing {
                // Model just loaded and note needs transcription
                transcribeAudio()
            }
        }
        .alert("Model Not Loaded", isPresented: $showLoadModelPrompt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please load a model in Settings first to transcribe this recording.")
        }
        .onAppear {
            loadAudioFile()
            editedTitle = note.title
            editedTranscription = note.transcription
        }
        .onChange(of: note.id) { _, _ in
            loadAudioFile()
            editedTitle = note.title
            editedTranscription = note.transcription
        }
    }

    private var detailHeaderCard: some View {
        SectionCard {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: note.transcription.isEmpty ? "waveform.circle.fill" : "text.quote")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if isEditing {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Note title", text: $editedTitle)
                                .font(.title2.weight(.semibold))
                                .textFieldStyle(.plain)

                            Divider()

                            Text(
                                note.timestamp,
                                format: Date.FormatStyle(date: .complete, time: .shortened)
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.title)
                                .font(.title2.weight(.semibold))

                            Text(
                                note.timestamp,
                                format: Date.FormatStyle(date: .complete, time: .shortened)
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        StatusBadge(
                            title: formatDuration(note.duration),
                            systemImage: "clock",
                            tint: .secondary
                        )

                        if note.isTranscribing || isTranscribing {
                            StatusBadge(
                                title: "Processing",
                                systemImage: "waveform.badge.magnifyingglass",
                                tint: Color.accentColor
                            )
                        } else if note.pendingTranscription {
                            StatusBadge(
                                title: "Pending",
                                systemImage: "clock.arrow.circlepath",
                                tint: .orange
                            )
                        } else if !note.transcription.isEmpty {
                            StatusBadge(
                                title: "Transcript ready",
                                systemImage: "checkmark.circle.fill",
                                tint: .green
                            )
                        }
                    }
                }

                Spacer(minLength: 12)

                Button(action: toggleEdit) {
                    Text(isEditing ? "Done" : "Edit")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var audioPlayerCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Playback")
                        .font(.headline)

                    Spacer()

                    playbackRateMenu
                }

                VStack(spacing: 8) {
                    ProgressView(value: audioPlayer.currentTime, total: max(audioPlayer.duration, 1))
                        .tint(.accentColor)

                    HStack {
                        Text(formatTime(audioPlayer.currentTime))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(formatTime(audioPlayer.duration))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 18) {
                    Spacer()

                    transportButton(systemImage: "gobackward.5", size: 44) {
                        audioPlayer.seekBackward()
                    }

                    Button(action: { audioPlayer.togglePlayPause() }) {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.accentColor.gradient))
                            .shadow(color: Color.accentColor.opacity(0.24), radius: 14, y: 8)
                    }
                    .buttonStyle(.plain)

                    transportButton(systemImage: "goforward.5", size: 44) {
                        audioPlayer.seekForward()
                    }

                    Spacer()
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
            Label(String(format: "%.2gx", audioPlayer.playbackRate), systemImage: "speedometer")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered)
    }

    private var transcriptionCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcription")
                            .font(.headline)

                        if note.lastTranscriptionDuration > 0 {
                            Text(
                                "Last run: \(transcriptionService.formatTranscriptionDuration(note.lastTranscriptionDuration))."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    transcriptionActions
                }

                Group {
                    if note.isTranscribing || isTranscribing {
                        transcriptionProgressContent
                    } else if !note.transcription.isEmpty {
                        transcriptionTextContent
                    } else if note.pendingTranscription {
                        pendingTranscriptionContent
                    } else {
                        emptyTranscriptionContent
                    }
                }
            }
        }
    }

    private var transcriptionActions: some View {
        HStack(spacing: 10) {
            if !note.transcription.isEmpty {
                Button(action: copyTranscription) {
                    Image(systemName: "square.on.square")
                }
                .buttonStyle(.bordered)

                Button(action: shareTranscription) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            if note.transcription.isEmpty {
                Button(action: { requestTranscription(force: true) }) {
                    Label("Transcribe", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(note.audioFilePath.isEmpty || note.isTranscribing || isTranscribing)
            } else {
                Button(action: { requestTranscription(force: true) }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(note.audioFilePath.isEmpty || note.isTranscribing || isTranscribing)
            }
        }
    }

    private var transcriptionProgressContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProgressView()
                Text("Transcribing audio…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(note.transcriptionProgress * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: note.transcriptionProgress)
                .tint(.accentColor)

            Button(role: .cancel, action: cancelCurrentTranscription) {
                Label("Cancel Transcription", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
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

            Text("This recording is saved locally and can be transcribed as soon as a model is available.")
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
            audioPlayer.loadAudio(from: note.audioFilePath)
        }
    }

    private func toggleEdit() {
        if isEditing {
            // Save changes
            note.title = editedTitle
            note.transcription = editedTranscription
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

    private func requestTranscription(force: Bool = false) {
        guard !note.audioFilePath.isEmpty else { return }

        guard isModelLoaded else {
            showLoadModelPrompt = true
            return
        }

        transcribeAudio(force: force)
    }

    private func transcribeAudio(force: Bool = false) {
        guard isModelLoaded, !note.audioFilePath.isEmpty else { return }
        guard force || note.pendingTranscription else { return }
        guard !note.isTranscribing else { return }

        isTranscribing = true
        note.isTranscribing = true
        note.transcriptionProgress = 0.0

        Task {
            let result = await transcriptionService.transcribeAudio(
                filePath: note.audioFilePath
            ) { progress in
                Task { @MainActor in
                    note.transcriptionProgress = progress
                }
            }

            await MainActor.run {
                isTranscribing = false
                note.isTranscribing = false

                if let result = result {
                    note.transcription = result.text
                    note.lastTranscriptionDuration = result.duration
                    note.pendingTranscription = false
                    editedTranscription = result.text
                } else {
                    note.transcriptionProgress = 0.0
                    if !force {
                        note.pendingTranscription = true
                    }
                }
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
        transcriptionService.cancelTranscription()
        isTranscribing = false
        note.isTranscribing = false
        note.transcriptionProgress = 0.0
        note.pendingTranscription = true
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
    private let content: Content

    init(
        backgroundColor: Color = Color(.secondarySystemGroupedBackground),
        borderColor: Color = Color.primary.opacity(0.05),
        @ViewBuilder content: () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
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

private struct LibrarySummaryCard: View {
    let title: String
    let subtitle: String
    let noteCount: Int
    let isCloudEnabled: Bool

    var body: some View {
        SectionCard {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 60, height: 60)

                    Image(systemName: "waveform.badge.mic")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        StatusBadge(
                            title: noteCount == 1 ? "1 note" : "\(noteCount) notes",
                            systemImage: "text.badge.checkmark",
                            tint: .secondary
                        )

                        if isCloudEnabled {
                            StatusBadge(
                                title: "iCloud enabled",
                                systemImage: "icloud.fill",
                                tint: .blue
                            )
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
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
