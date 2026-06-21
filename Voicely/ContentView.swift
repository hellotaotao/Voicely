//
//  ContentView.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import AVFoundation
import CoreML
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VoiceNote.timestamp, order: .reverse) private var voiceNotes: [VoiceNote]
    @StateObject private var audioService = AudioRecordingService()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var transcriptionService = TranscriptionService()
    @ObservedObject private var cloudManager = CloudStorageManager.shared
    @EnvironmentObject private var syncMonitor: CloudKitSyncMonitor
    @State private var selectedNoteID: UUID?
    @State private var showingSettings = false
    @State private var didSetupServices = false
    @State private var startRecordingQuickActionID = UUID()
    @State private var togglePauseQuickActionID = UUID()
    @State private var recordingInterruptionID = UUID()
    @State private var recordingInterruptionNotice: String?
    @State private var inboundAudioImportError: String?
    @State private var shouldShowFirstLaunchOnboarding = FirstLaunchOnboarding.shouldPresent()
    @State private var compactNavigationPath: [UUID] = []

    private var isPhoneDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

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
            .background(VoicelyTheme.groupedBackground)
        }
        .tint(VoicelyTheme.accent)
        .onAppear {
            syncInitialSelection()
            consumePendingStartRecordingQuickActionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startRecordingQuickAction)) { _ in
            consumePendingStartRecordingQuickActionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecordingPauseQuickAction)) { _ in
            requestTogglePauseFromQuickAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingInterruptedBySystem)) { _ in
            recordingInterruptionID = UUID()
            recordingInterruptionNotice = "An incoming call or another app interrupted recording. What you recorded so far has been saved. Start a new recording to continue."
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelLoadedNotification)) { _ in
            Task { @MainActor in
                await processQueuedTranscriptionsIfReady()
            }
        }
        .onChange(of: voiceNotes.count) { _, _ in
            syncInitialSelection()
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { inboundAudioImportError != nil },
                set: { isPresented in
                    if !isPresented {
                        inboundAudioImportError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                inboundAudioImportError = nil
            }
        } message: {
            Text(inboundAudioImportError ?? "")
        }
        .alert(
            "Recording Stopped",
            isPresented: Binding(
                get: { recordingInterruptionNotice != nil },
                set: { isPresented in
                    if !isPresented {
                        recordingInterruptionNotice = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                recordingInterruptionNotice = nil
            }
        } message: {
            Text(recordingInterruptionNotice ?? "")
        }
        .overlay {
            if shouldShowFirstLaunchOnboarding {
                FirstLaunchOnboardingView(
                    modelSetupStatus: onboardingModelSetupStatus,
                    onComplete: completeFirstLaunchOnboarding
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shouldShowFirstLaunchOnboarding)
    }

    private var onboardingModelSetupStatus: FirstLaunchModelSetupStatus {
        FirstLaunchOnboarding.modelSetupStatus(
            for: modelManager.modelState,
            progress: modelManager.loadingProgressValue,
            errorMessage: modelManager.errorMessage
        )
    }

    private func completeFirstLaunchOnboarding() {
        FirstLaunchOnboarding.markCompleted()
        withAnimation(.easeInOut(duration: 0.2)) {
            shouldShowFirstLaunchOnboarding = false
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
            .background(VoicelyTheme.groupedBackground)
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
        .accessibilityIdentifier(AccessibilityIdentifiers.Navigation.libraryScreen)
    }

    @ViewBuilder
    private var defaultNavigationView: some View {
        if isPhoneDevice {
            compactPhoneNavigationView
        } else {
            splitNavigationView
        }
    }

    private var compactPhoneNavigationView: some View {
        NavigationStack(path: $compactNavigationPath) {
            noteLibraryList(
                usesSplitNavigationSelection: false,
                opensDetailInCompactStack: true,
                showsRecordingControls: false
            )
            .navigationTitle("Voicely")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                libraryToolbarContent
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: UUID.self) { noteID in
                if let note = voiceNotes.first(where: { $0.id == noteID }) {
                    detailView(note)
                } else {
                    DetailPlaceholderView()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // One recording bar, pinned to the stack so it floats over both the
            // list and any pushed detail. On the list it is always available
            // (idle → start). It only floats into a pushed detail while a
            // recording is active (pause/stop); once you stop there it
            // disappears, so a new recording can only be started from the list.
            if compactNavigationPath.isEmpty || audioService.isRecording {
                recordingControlsBar(opensDetailInCompactStack: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(modelManager)
        }
        .task {
            await setupServices()
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Navigation.libraryScreen)
    }

    private var splitNavigationView: some View {
        NavigationSplitView {
            noteLibraryList(
                usesSplitNavigationSelection: true,
                opensDetailInCompactStack: false
            )
                .navigationTitle("Voicely")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    libraryToolbarContent
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
        .accessibilityIdentifier(AccessibilityIdentifiers.Navigation.libraryScreen)
    }

    @ToolbarContentBuilder
    private var libraryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.regular))
            }
            .tint(VoicelyTheme.accent)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier(AccessibilityIdentifiers.Navigation.settingsButton)
        }

        ToolbarItem(placement: .principal) {
            if cloudManager.isCloudEnabled {
                SyncStatusView()
                    .environmentObject(cloudManager)
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            EditButton()
                .tint(VoicelyTheme.accent)
        }
    }

    private func sidebarWidth(for geometry: GeometryProxy) -> CGFloat {
        min(max(geometry.size.width * 0.36, 300), 400)
    }

    private var compactSplitHeader: some View {
        HStack(spacing: 12) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.regular))
                    .foregroundStyle(VoicelyTheme.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier(AccessibilityIdentifiers.Navigation.settingsButton)

            Spacer()

            if cloudManager.isCloudEnabled {
                SyncStatusView()
                    .environmentObject(cloudManager)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private func noteLibraryList(
        usesSplitNavigationSelection: Bool,
        opensDetailInCompactStack: Bool = false,
        showsRecordingControls: Bool = true
    ) -> some View {
        ZStack(alignment: .bottom) {
            noteList(
                usesSplitNavigationSelection: usesSplitNavigationSelection,
                opensDetailInCompactStack: opensDetailInCompactStack
            )
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(VoicelyTheme.groupedBackground)
                .contentMargins(.bottom, showsRecordingControls ? sidebarRecordingOverlayInset : 16, for: .scrollContent)
                .refreshable {
                    await cloudManager.refreshSync()
                }

            if showsRecordingControls {
                recordingControlsBar(opensDetailInCompactStack: opensDetailInCompactStack)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .zIndex(1)
            }
        }
        .background(VoicelyTheme.groupedBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Navigation.libraryScreen)
    }

    private func recordingControlsBar(opensDetailInCompactStack: Bool) -> some View {
        RecordingControls(
            audioService: audioService,
            transcriptionService: transcriptionService,
            startRecordingQuickActionID: startRecordingQuickActionID,
            togglePauseQuickActionID: togglePauseQuickActionID,
            recordingInterruptionID: recordingInterruptionID,
            onManageModels: {
                showingSettings = true
            },
            onRecordingComplete: { note in
                modelContext.insert(note)
                selectedNoteID = note.id
                if opensDetailInCompactStack {
                    compactNavigationPath = [note.id]
                }
            }
        )
    }

    @ViewBuilder
    private func noteList(
        usesSplitNavigationSelection: Bool,
        opensDetailInCompactStack: Bool
    ) -> some View {
        if usesSplitNavigationSelection {
            List(selection: $selectedNoteID) {
                noteListContent(
                    usesSplitNavigationSelection: true,
                    opensDetailInCompactStack: false
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.Library.noteList)
        } else {
            List {
                noteListContent(
                    usesSplitNavigationSelection: false,
                    opensDetailInCompactStack: opensDetailInCompactStack
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.Library.noteList)
        }
    }

    @ViewBuilder
    private func noteListContent(
        usesSplitNavigationSelection: Bool,
        opensDetailInCompactStack: Bool
    ) -> some View {
        if shouldShowSyncStatusBanner {
            Section {
                SyncStatusBannerCard(
                    description: syncMonitor.statusDescription,
                    tint: syncMonitor.statusColor,
                    showsRetry: shouldShowSyncRetry,
                    retryAction: {
                        Task {
                            await syncMonitor.checkCloudKitAccountStatus()
                        }
                    }
                )
                .accessibilityIdentifier(AccessibilityIdentifiers.Library.syncStatusBanner)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }

        Section {
            if voiceNotes.isEmpty {
                EmptyLibraryCard()
                    .accessibilityIdentifier(AccessibilityIdentifiers.Library.emptyState)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(voiceNotes) { note in
                    noteRow(
                        note: note,
                        usesSplitNavigationSelection: usesSplitNavigationSelection,
                        opensDetailInCompactStack: opensDetailInCompactStack
                    )
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
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
        } header: {
            if !voiceNotes.isEmpty {
                SectionHeaderLabel(text: "Recordings")
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    private var shouldShowSyncStatusBanner: Bool {
        switch syncMonitor.syncStatus {
        case .idle, .available:
            return false
        case .error(let message):
            return message != "No iCloud account found"
        case .checkingAccount, .recovering:
            return true
        }
    }

    private var shouldShowSyncRetry: Bool {
        guard case .error(let message) = syncMonitor.syncStatus else {
            return false
        }
        return message != "No iCloud account found"
    }

    private func noteRow(
        note: VoiceNote,
        usesSplitNavigationSelection: Bool,
        opensDetailInCompactStack: Bool
    ) -> some View {
        let row = VoiceNoteRow(
            note: note,
            isLocallyTranscribing: transcriptionService.isLocallyTranscribing(note),
            isRemoteTranscribing: transcriptionService.isTranscribingOnAnotherDevice(note),
            isPending: transcriptionService.shouldShowPendingState(note),
            localProgress: transcriptionService.localProgress(for: note),
            isRecordingPaused: isRecordingPaused(note),
            isSelected: selectedNoteID == note.id
        )

        return Group {
            if usesSplitNavigationSelection {
                NavigationLink(value: note.id) {
                    row.foregroundStyle(.primary)
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.Library.noteRow)
            } else {
                Button {
                    selectedNoteID = note.id
                    if opensDetailInCompactStack {
                        compactNavigationPath = [note.id]
                    }
                } label: {
                    row.foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.Library.noteRow)
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
        .background(VoicelyTheme.groupedBackground)
    }

    private func detailView(_ note: VoiceNote) -> some View {
        VoiceNoteDetailView(
            note: note,
            audioService: audioService,
            showingSettings: $showingSettings
        )
            .environmentObject(transcriptionService)
    }

    private var sidebarRecordingOverlayInset: CGFloat {
        112
    }

    private func syncInitialSelection() {
        guard !voiceNotes.isEmpty else {
            selectedNoteID = nil
            compactNavigationPath = []
            return
        }

        guard let selectedNoteID else {
            if !isPhoneDevice {
                self.selectedNoteID = voiceNotes.first?.id
            }
            return
        }

        guard voiceNotes.contains(where: { $0.id == selectedNoteID }) else {
            self.selectedNoteID = isPhoneDevice ? nil : voiceNotes.first?.id
            if isPhoneDevice {
                compactNavigationPath = []
            }
            return
        }
    }

    private func setupServices() async {
        guard !didSetupServices else { return }
        didSetupServices = true

        guard !AppRuntime.isRunningTests else {
            transcriptionService.setModelManager(modelManager)
            consumePendingStartRecordingQuickActionIfNeeded()
            return
        }

        transcriptionService.setModelManager(modelManager)
        await modelManager.fetchModels(includeRemote: false)
        transcriptionService.migrateLegacyOwnershipIfNeeded(notes: voiceNotes)

        if cloudManager.isCloudEnabled {
            await cloudManager.migrateLocalFilesToCloudIfNeeded()
            await cloudManager.refreshSync()
        }

        consumePendingStartRecordingQuickActionIfNeeded()

        if !transcriptionService.isWhisperAvailable() {
            Task {
                let didLoadModel = await transcriptionService.loadWhisperModel()
                if didLoadModel {
                    await processQueuedTranscriptionsIfReady()
                }
            }
        } else {
            await processQueuedTranscriptionsIfReady()
        }
    }

    private func processQueuedTranscriptionsIfReady() async {
        transcriptionService.setModelManager(modelManager)

        guard transcriptionService.isWhisperAvailable() else {
            return
        }

        let eligibleNotes = voiceNotes.filter { note in
            !note.isTranscribing
        }

        guard !eligibleNotes.isEmpty else {
            return
        }

        await transcriptionService.processPendingTranscriptions(notes: eligibleNotes)
    }

    private func handleIncomingURL(_ url: URL) {
        if let deepLink = VoicelyDeepLink(url: url) {
            handleDeepLink(deepLink)
            return
        }

        Task { @MainActor in
            await importIncomingAudio(from: url)
        }
    }

    private func handleDeepLink(_ deepLink: VoicelyDeepLink) {
        switch deepLink {
        case .startRecording:
            requestStartRecordingFromQuickAction()
        case .toggleRecordingPause:
            requestTogglePauseFromQuickAction()
        }
    }

    private func importIncomingAudio(from url: URL) async {
        transcriptionService.setModelManager(modelManager)

        do {
            let importedAudio = try cloudManager.importAudioFile(from: url)
            let note = VoiceNote(
                title: importedAudio.title,
                audioFilePath: importedAudio.filePath
            )
            // The imported file name is a meaningful, user-facing title; keep it
            // rather than overwriting it with an auto-derived transcript title.
            note.titleWasManuallyEdited = true
            note.duration = await audioDuration(for: importedAudio.fileURL)

            let isModelLoaded = transcriptionService.isWhisperAvailable()
            transcriptionService.configureNewNote(note, shouldStartImmediately: isModelLoaded)

            modelContext.insert(note)
            try modelContext.save()
            selectedNoteID = note.id

            if isModelLoaded {
                await transcriptionService.processPendingTranscriptions(notes: [note])
                return
            }

            let didLoadModel = await transcriptionService.loadWhisperModel()
            if didLoadModel {
                await transcriptionService.processPendingTranscriptions(notes: [note])
            }
        } catch {
            inboundAudioImportError = error.localizedDescription
        }
    }

    private func audioDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : 0
        } catch {
            debugLog("Failed to read imported audio duration: \(error.localizedDescription)")
            return 0
        }
    }

    private func consumePendingStartRecordingQuickActionIfNeeded() {
        guard QuickAction.consumePendingStartRecording() else { return }
        requestStartRecordingFromQuickAction()
    }

    private func requestStartRecordingFromQuickAction() {
        startRecordingQuickActionID = UUID()
    }

    private func requestTogglePauseFromQuickAction() {
        togglePauseQuickActionID = UUID()
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
        if transcriptionService.isLocallyTranscribing(note) {
            transcriptionService.cancelTranscription(for: note)
        }

        if !note.audioFilePath.isEmpty {
            cloudManager.deleteFile(at: note.audioFilePath)
        }

        if selectedNoteID == note.id {
            if isPhoneDevice {
                selectedNoteID = nil
                compactNavigationPath = []
            } else {
                selectedNoteID = voiceNotes.first { $0.id != note.id }?.id
            }
        }

        modelContext.delete(note)
    }

    private func cancelTranscription(for note: VoiceNote) {
        transcriptionService.cancelTranscription(for: note)
    }

    private func isRecordingPaused(_ note: VoiceNote) -> Bool {
        audioService.isRecording
            && audioService.isPaused
            && note.isTranscribing
            && note.duration <= 0
    }
}

// MARK: - Voice Note Row

struct VoiceNoteRow: View {
    // Plain values instead of observing TranscriptionService: high-frequency
    // progress publishes then only re-render rows whose inputs changed.
    let note: VoiceNote
    let isLocallyTranscribing: Bool
    let isRemoteTranscribing: Bool
    let isPending: Bool
    let localProgress: Float
    let isRecordingPaused: Bool
    var isSelected = false

    private var isAwaitingTranscription: Bool {
        note.isAwaitingTranscription
    }

    private var hasVisibleTranscript: Bool {
        !note.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isLiveUpdatingTranscript: Bool {
        note.isTranscribing && hasVisibleTranscript && !isLocallyTranscribing && !isAwaitingTranscription && !isRemoteTranscribing
    }

    private var isRecordingInProgress: Bool {
        note.isTranscribing && note.duration <= 0 && !isLocallyTranscribing && !isAwaitingTranscription && !isRemoteTranscribing
    }

    private var isFinalizingTranscription: Bool {
        note.isTranscribing && note.duration > 0 && !hasVisibleTranscript && !isLocallyTranscribing && !isAwaitingTranscription && !isRemoteTranscribing
    }

    private var previewText: String? {
        let trimmed = note.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if isLocallyTranscribing { return "Transcribing…" }
        if isRecordingPaused { return "Recording paused. Resume when you are ready." }
        if isRecordingInProgress { return "Recording… waiting for the first live transcript." }
        if isFinalizingTranscription { return "Finalizing transcription…" }
        if isAwaitingTranscription { return "Queued for transcription." }
        if isRemoteTranscribing { return "Transcribing on another device." }
        if note.transcriptionOutcome == .noSpeech { return "No speech detected." }
        if note.transcriptionOutcome == .failed { return "Couldn't transcribe. Open to try again." }
        return nil
    }

    private var statusBadge: PillBadge? {
        if isLocallyTranscribing {
            return PillBadge(text: "Transcribing…", systemImage: "waveform", variant: .accent)
        } else if isRecordingPaused {
            return PillBadge(text: "Paused", systemImage: "pause.circle", variant: .warning)
        } else if isLiveUpdatingTranscript {
            return PillBadge(text: "Live transcript", systemImage: "waveform", variant: .accent)
        } else if isRecordingInProgress {
            return PillBadge(text: "Recording", systemImage: "record.circle", variant: .danger)
        } else if isFinalizingTranscription {
            return PillBadge(text: "Finalizing", systemImage: "waveform", variant: .accent)
        } else if isAwaitingTranscription {
            return PillBadge(text: "Queued", systemImage: "clock.arrow.circlepath", variant: .warning)
        } else if isRemoteTranscribing {
            return PillBadge(text: "Another device", systemImage: "laptopcomputer.and.iphone", variant: .info)
        } else if isPending {
            return PillBadge(text: "Transcription pending", systemImage: "clock.arrow.circlepath", variant: .warning)
        } else if note.transcriptionOutcome == .noSpeech {
            return PillBadge(text: "No speech", systemImage: "waveform.slash", variant: .neutral)
        } else if note.transcriptionOutcome == .failed {
            return PillBadge(text: "Tap to retry", systemImage: "arrow.clockwise", variant: .warning)
        }
        return nil
    }

    private var durationText: String {
        // Only shown when not recording (see body), so this is always the
        // finished recording's total length.
        formatDuration(note.duration)
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? VoicelyTheme.accent : Color.clear)
                .frame(width: 2.5)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(note.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isSelected ? VoicelyTheme.accent : .primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // While recording, leave this slot empty: the status badge
                    // already says "Recording"/"Paused", and the row has no
                    // access to the live elapsed time. The total duration
                    // appears here once the recording finishes.
                    if !isRecordingInProgress {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .font(.caption2)
                            Text(durationText)
                                .font(.caption)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.tertiary)
                    }
                }

                Text(note.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let previewText {
                    Text(previewText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }

                if isLocallyTranscribing {
                    ProgressView(value: localProgress)
                        .tint(.accentColor)
                        .padding(.top, 4)
                }

                if let statusBadge {
                    statusBadge
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(rowBorderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.07 : 0.035), radius: isSelected ? 8 : 4, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var rowBorderColor: Color {
        isSelected ? VoicelyTheme.accent.opacity(0.32) : Color.primary.opacity(0.075)
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                VoicelyTheme.accent.opacity(0.12)
            } else {
                VoicelyTheme.surface.opacity(0.72)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

// MARK: - Recording Controls

struct RecordingControls: View {
    @ObservedObject var audioService: AudioRecordingService
    @ObservedObject var transcriptionService: TranscriptionService
    let startRecordingQuickActionID: UUID
    let togglePauseQuickActionID: UUID
    let recordingInterruptionID: UUID
    let onManageModels: () -> Void
    let onRecordingComplete: (VoiceNote) -> Void
    @State private var showingModelPicker = false
    @State private var coordinator: IncrementalTranscriptionCoordinator? = nil
    @State private var currentRecordingNote: VoiceNote? = nil
    @State private var isStartingRecording = false
    @State private var recordingStartedAt: Date?

    private var controlPhase: RecordingControlPhase {
        RecordingControlState.phase(
            isRecording: audioService.isRecording,
            isStarting: isStartingRecording
        )
    }

    private var canStopRecording: Bool {
        RecordingControlState.shouldAcceptStopRequest(
            isStarting: isStartingRecording,
            recordingStartedAt: recordingStartedAt,
            now: Date(),
            recordingDuration: audioService.recordingDuration
        )
    }

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
        return ModelManager.displayNameWithLanguageTag(for: selectedModel)
    }

    private var statusTint: Color {
        if !audioService.hasPermission { return .orange }
        guard let modelManager else { return .secondary }
        switch modelManager.modelState {
        case .loaded: return .green
        case .loading, .downloading, .prewarming: return .orange
        case .unloaded: return modelManager.isModelAvailableOffline(modelManager.selectedModel) ? .secondary : .accentColor
        }
    }

    private var recordingTint: Color {
        audioService.isPaused ? .orange : .red
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
        return "Choose an offline model for new transcriptions."
    }

    private var effectiveIncrementalIntervalSeconds: Int {
        IncrementalTranscriptionTiming.defaultIntervalSeconds
    }

    var body: some View {
        Group {
            switch controlPhase {
            case .recording:
                recordingLayout
            case .starting:
                startingLayout
            case .idle:
                idleLayout
            }
        }
        .padding(8)
        .background(recordingControlBackground)
        .overlay(recordingControlBorder)
        .shadow(color: Color.black.opacity(0.28), radius: 22, x: 0, y: 12)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: controlPhase)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: audioService.isPaused)
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
            Button("Manage Models…") { onManageModels() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(modelPickerMessage)
        }
        .onChange(of: startRecordingQuickActionID) { _, _ in
            startRecordingFromQuickAction()
        }
        .onChange(of: togglePauseQuickActionID) { _, _ in
            togglePauseResumeFromQuickAction()
        }
        .onChange(of: recordingInterruptionID) { _, _ in
            stopRecordingDueToInterruption()
        }
        .onAppear {
            audioService.prewarmRecordingSessionIfPossible()
            registerLiveActivityControls()
        }
        .onChange(of: audioService.hasPermission) { _, _ in
            audioService.prewarmRecordingSessionIfPossible()
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingControls)
    }

    private var recordingControlBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(VoicelyTheme.surface.opacity(0.58))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.06),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var recordingControlBorder: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.34),
                        Color.primary.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var idleLayout: some View {
        HStack(spacing: 10) {
            Button {
                showingModelPicker = true
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(statusTint)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Model")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(selectedModelDisplayName)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(VoicelyTheme.surface.opacity(0.68))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingModelPickerButton)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Selected Model \(selectedModelDisplayName)")
            .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingModelPickerButton)

            recordButton
        }
    }

    private var startingLayout: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Starting recording")
                        .font(.footnote.weight(.semibold))
                    Text("Preparing microphone…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VoicelyTheme.accent.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(VoicelyTheme.accent.opacity(0.22), lineWidth: 1)
            )

            Image(systemName: "mic.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.55))
                .frame(width: 44, height: 44)
                .background(Circle().fill(VoicelyTheme.accent.opacity(0.45)))
        }
        .accessibilityLabel("Starting recording")
    }

    private var recordingLayout: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(recordingTint)
                    .frame(width: 8, height: 8)
                    .opacity(audioService.isPaused ? 0.65 : 1.0)

                AudioWaveformView(
                    isAnimating: audioService.isRecording && !audioService.isPaused,
                    audioService: audioService
                )
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatDuration(audioService.recordingDuration))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(recordingTint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(recordingTint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(recordingTint.opacity(0.22), lineWidth: 1)
            )

            Button(action: togglePauseResume) {
                Image(systemName: audioService.isPaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioService.isPaused ? "Resume" : "Pause")
            .accessibilityIdentifier(AccessibilityIdentifiers.Library.pauseRecordingButton)

            stopButton
        }
    }

    private var recordButton: some View {
        Button(action: startRecording) {
            Image(systemName: audioService.hasPermission ? "mic.fill" : "mic.slash.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.black)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(audioService.hasPermission ? VoicelyTheme.accent : Color.gray)
                )
                .shadow(color: audioService.hasPermission ? VoicelyTheme.accent.opacity(0.35) : .clear, radius: 12, y: 4)
                .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordButton)
        }
        .buttonStyle(.plain)
        .disabled(!audioService.hasPermission || isStartingRecording)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(audioService.hasPermission ? "Record" : "Record unavailable")
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordButton)
    }

    private var stopButton: some View {
        Button(action: stopRecording) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.red))
                .shadow(color: Color.red.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!canStopRecording)
        .opacity(canStopRecording ? 1 : 0.55)
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.stopRecordingButton)
    }

    private func startRecording() {
        guard !isStartingRecording,
              !audioService.isRecording,
              currentRecordingNote == nil else { return }

        isStartingRecording = true

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard isStartingRecording else { return }
            beginRecordingAfterFeedback()
        }
    }

    private func beginRecordingAfterFeedback() {
        var didStart = false
        defer {
            if !didStart {
                isStartingRecording = false
                recordingStartedAt = nil
            }
        }

        guard let filePath = audioService.startRecording() else { return }
        guard let pcmURL = audioService.currentPCMFileURL else {
            _ = audioService.stopRecording()
            return
        }

        let note = makeRecordingNote(filePath: filePath)
        transcriptionService.configureNewNote(note, shouldStartImmediately: true)
        note.isTranscribing = true
        note.transcriptionProgress = 0.0
        currentRecordingNote = note
        recordingStartedAt = Date()
        isStartingRecording = false
        didStart = true
        onRecordingComplete(note)
        RecordingLiveActivityController.shared.start(recordingID: note.id, title: note.title)

        let coord = IncrementalTranscriptionCoordinator(
            transcriptionService: transcriptionService,
            recordingFileURL: pcmURL
        )
        coord.frameCountProvider = { [weak audioService] in
            audioService?.currentFramePosition ?? 0
        }
        coord.transcriptCallback = { [note] transcript in
            guard let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(transcript) else { return }

            note.transcription = finalizedTranscript.text
            note.isTranscribing = true
            note.transcriptionModelIdentifier = transcriptionService.modelManager?.currentModelIdentifier()
                ?? transcriptionService.modelManager?.selectedModel
            note.transcriptionLastErrorMessage = nil
            note.recordTranscriptionTelemetry(transcriptionService.transcriptionTelemetry)
        }
        coordinator = coord
        registerLiveActivityControls(coordinator: coord)
        coord.start(intervalSeconds: effectiveIncrementalIntervalSeconds)
    }

    private func startRecordingFromQuickAction() {
        guard !audioService.isRecording, !isStartingRecording else { return }

        if !isModelLoaded && !isModelLoading {
            Task {
                let _ = await transcriptionService.loadWhisperModel()
            }
        }

        startRecording()
    }

    private func togglePauseResume() {
        Self.togglePauseResume(
            audioService: audioService,
            coordinator: coordinator,
            incrementalIntervalSeconds: effectiveIncrementalIntervalSeconds
        )
    }

    private func togglePauseResumeFromQuickAction() {
        guard audioService.isRecording else { return }
        togglePauseResume()
    }

    private func registerLiveActivityControls(coordinator: IncrementalTranscriptionCoordinator? = nil) {
        RecordingControlCommandCenter.shared.setTogglePauseHandler { [audioService] in
            guard audioService.isRecording else { return }
            Self.togglePauseResume(
                audioService: audioService,
                coordinator: coordinator,
                incrementalIntervalSeconds: effectiveIncrementalIntervalSeconds
            )
        }
    }

    private static func togglePauseResume(
        audioService: AudioRecordingService,
        coordinator: IncrementalTranscriptionCoordinator?,
        incrementalIntervalSeconds: Int
    ) {
        if audioService.isPaused {
            guard audioService.resumeRecording() else { return }
            coordinator?.resume(intervalSeconds: incrementalIntervalSeconds)
            RecordingLiveActivityController.shared.resume(elapsedDuration: audioService.recordingDuration)
        } else {
            audioService.pauseRecording()
            coordinator?.pause()
            RecordingLiveActivityController.shared.pause(elapsedDuration: audioService.recordingDuration)
        }
    }

    private func stopRecording() {
        guard RecordingControlState.shouldAcceptStopRequest(
            isStarting: isStartingRecording,
            recordingStartedAt: recordingStartedAt,
            now: Date(),
            recordingDuration: audioService.recordingDuration
        ) else {
            return
        }

        finalizeRecording()
    }

    /// Force-finalizes the active recording without the accidental-stop guard.
    /// Used when the system interrupts recording (incoming call, another app
    /// taking the audio session) — an interruption is never accidental and may
    /// arrive within the first second of recording.
    private func stopRecordingDueToInterruption() {
        guard audioService.isRecording else { return }
        finalizeRecording()
    }

    private func finalizeRecording() {
        let capturedCoordinator = coordinator
        let recordingNote = currentRecordingNote
        coordinator = nil
        registerLiveActivityControls()
        currentRecordingNote = nil
        isStartingRecording = false
        recordingStartedAt = nil

        let finalFrame = audioService.currentFramePosition
        let stopResult = audioService.stopRecording()
        RecordingLiveActivityController.shared.end(elapsedDuration: stopResult.duration)

        guard let filePath = stopResult.filePath else { return }

        let note: VoiceNote
        if let recordingNote {
            note = recordingNote
        } else {
            note = makeRecordingNote(filePath: filePath)
            onRecordingComplete(note)
        }

        note.audioFilePath = filePath
        note.duration = stopResult.duration
        note.isTranscribing = true
        note.pendingTranscription = false
        note.transcriptionProgress = 0.0

        Task { @MainActor in
            let accumulatedTranscript: String
            if let coord = capturedCoordinator {
                accumulatedTranscript = await coord.stop(currentFrame: finalFrame)
            } else {
                accumulatedTranscript = ""
            }

            let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(accumulatedTranscript)
            let trimmedTranscript = finalizedTranscript?.text ?? ""

            if !trimmedTranscript.isEmpty {
                note.transcription = trimmedTranscript
                note.transcriptionModelIdentifier = transcriptionService.modelManager?.currentModelIdentifier()
                    ?? transcriptionService.modelManager?.selectedModel
                note.recordTranscriptionTelemetry(transcriptionService.transcriptionTelemetry)
                note.completeTranscription()
                note.clearTransientTranscriptionFlags()
                return
            }

            await stopResult.awaitConversionIfNeeded(forIncrementalTranscript: trimmedTranscript)
            transcriptionService.configureNewNote(note, shouldStartImmediately: isModelLoaded)
            if isModelLoaded {
                await transcriptionService.processPendingTranscriptions(notes: [note])
            }
        }
    }

    private func makeRecordingNote(filePath: String) -> VoiceNote {
        VoiceNote(
            title: "Voice Note \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))",
            audioFilePath: filePath
        )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func modelPickerButtonTitle(for model: String) -> String {
        let displayName = ModelManager.displayNameWithLanguageTag(for: model)
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
}

// MARK: - Voice Note Detail

struct VoiceNoteDetailView: View {
    let note: VoiceNote
    @ObservedObject var audioService: AudioRecordingService
    @Binding var showingSettings: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var transcriptionService: TranscriptionService
    @State private var showLoadModelPrompt = false
    @State private var showingShareSheet = false
    @State private var isEditing = false
    @State private var showingRetranscribeConfirmation = false
    @State private var editedTitle = ""
    @State private var editedTranscription = ""
    @State private var copyConfirmVisible = false
    @StateObject private var audioPlayer = AudioPlayerService()

    private var isModelLoaded: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.isModelLoaded()
    }

    private var selectedModelDisplayName: String? {
        guard let selectedModel = transcriptionService.modelManager?.selectedModel, !selectedModel.isEmpty else {
            return nil
        }
        return ModelManager.displayNameWithLanguageTag(for: selectedModel)
    }

    private var isLocallyTranscribing: Bool {
        transcriptionService.isLocallyTranscribing(note)
    }

    private var isAwaitingTranscription: Bool {
        note.isAwaitingTranscription
    }

    private var isRemoteTranscribing: Bool {
        transcriptionService.isTranscribingOnAnotherDevice(note)
    }

    private var hasVisibleTranscript: Bool {
        !note.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isLiveUpdatingTranscript: Bool {
        note.isTranscribing && hasVisibleTranscript && !isLocallyTranscribing && !isAwaitingTranscription && !isRemoteTranscribing
    }

    private var isRecordingInProgress: Bool {
        note.isTranscribing && note.duration <= 0 && !isLocallyTranscribing && !isAwaitingTranscription && !isRemoteTranscribing
    }

    private var isRecordingPaused: Bool {
        isRecordingInProgress && audioService.isPaused
    }

    private var isFinalizingTranscription: Bool {
        note.isTranscribing && note.duration > 0 && !hasVisibleTranscript && !isLocallyTranscribing && !isAwaitingTranscription && !isRemoteTranscribing
    }

    private var isTranscribingHere: Bool {
        isLocallyTranscribing || isLiveUpdatingTranscript || isRecordingInProgress || isFinalizingTranscription
    }

    private var shouldShowTakeOverAction: Bool {
        note.transcription.isEmpty && isRemoteTranscribing
    }

    private var shouldShowPendingState: Bool {
        transcriptionService.shouldShowPendingState(note)
    }

    private var shouldShowPrimaryTranscribeActionInBody: Bool {
        isAwaitingTranscription || shouldShowPendingState
            || note.transcriptionOutcome == .noSpeech || note.transcriptionOutcome == .failed
    }

    private var localTranscriptionProgress: Float {
        if isLocallyTranscribing {
            return transcriptionService.localProgress(for: note)
        }
        return max(0, min(note.transcriptionProgress, 1))
    }

    private var shouldShowComputeTelemetry: Bool {
        isTranscribingHere
    }

    private var currentTelemetrySnapshot: TranscriptionTelemetrySnapshot {
        let serviceSnapshot = transcriptionService.transcriptionTelemetry
        if serviceSnapshot.isActive {
            return serviceSnapshot
        }

        let modelIdentifier = transcriptionService.modelManager?.currentModelIdentifier()
            ?? transcriptionService.modelManager?.selectedModel
        let modelName = modelIdentifier.map(ModelManager.displayName(for:)) ?? "No model"

        return TranscriptionTelemetrySnapshot.inactive(
            modelName: modelName,
            computeRoute: TranscriptionComputeRoute(
                encoderUnits: transcriptionService.modelManager?.encoderComputeUnits ?? .cpuAndNeuralEngine,
                decoderUnits: transcriptionService.modelManager?.decoderComputeUnits ?? .cpuAndNeuralEngine
            )
        )
    }

    private var usesCompactDetailLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact
    }

    /// Caps the detail content width only on Mac (Catalyst). On a very wide
    /// window — e.g. fullscreen on an ultrawide display — an unconstrained
    /// layout stretches the waveform and transcript across the whole screen.
    /// iPhone/iPad always fill, so no width is wasted there.
    private var detailContentMaxWidth: CGFloat {
        ProcessInfo.processInfo.isMacCatalystApp ? 1100 : .infinity
    }

    /// Shown under the transcription header when re-running would switch
    /// models — the "I picked a better model, now re-do it" case. nil when a
    /// re-run would reuse the model already applied, or there's nothing to
    /// re-transcribe yet, or transcription is currently running.
    private var retranscribeModelHint: String? {
        guard !note.transcription.isEmpty,
              !shouldShowTakeOverAction,
              !isTranscribingHere,
              !isRemoteTranscribing,
              let next = selectedModelDisplayName,
              let current = note.transcriptionModelDisplayName,
              next != current else {
            return nil
        }
        return "Re-transcribe will use \(next)"
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

    private var durationLabel: String {
        // While recording, show the live elapsed time here. The recording /
        // paused state itself is conveyed by the coloured status pill, so
        // repeating the word "Recording" in this slot would be redundant.
        if isRecordingInProgress { return formatTime(audioService.recordingDuration) }
        let total = Int(note.duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private var shouldShowAudioPlayerCard: Bool {
        !note.audioFilePath.isEmpty && !isRecordingInProgress
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBlock
                metadataRow

                if shouldShowAudioPlayerCard {
                    audioPlayerCard
                }

                transcriptionCard
            }
            .padding(usesCompactDetailLayout ? 16 : 20)
            .frame(maxWidth: detailContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(VoicelyTheme.groupedBackground)
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.screen)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesCompactDetailLayout {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: toggleEdit) {
                        Text(isEditing ? "Done" : "Edit")
                            .font(.body.weight(.medium))
                    }
                    .tint(VoicelyTheme.accent)
                    .accessibilityIdentifier(AccessibilityIdentifiers.Detail.editButton)
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [shareableTranscriptionText()])
        }
        .alert("Model Not Loaded", isPresented: $showLoadModelPrompt) {
            Button("Open Settings") { showingSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please load a model in Settings first to transcribe this recording.")
        }
        .confirmationDialog(
            "Re-transcribe this note?",
            isPresented: $showingRetranscribeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-transcribe") { requestTranscription(force: true) }
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

    private var headerBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Note title", text: $editedTitle)
                        .font(.title.weight(.bold))
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.title)
                } else {
                    Text(note.title)
                        .font(.title.weight(.bold))
                        .tracking(-0.5)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.title)
                }
                Text(note.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            if !usesCompactDetailLayout {
                Button(action: toggleEdit) {
                    HStack(spacing: 5) {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                            .font(.caption.weight(.semibold))
                        Text(isEditing ? "Done" : "Edit")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(VoicelyTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(VoicelyTheme.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.editButton)
            }
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        WrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            PillBadge(text: durationLabel, systemImage: "clock", variant: .neutral)

            if isLocallyTranscribing {
                PillBadge(text: "Processing", systemImage: "waveform", variant: .accent)
            } else if isRecordingPaused {
                PillBadge(text: "Paused", systemImage: "pause.circle", variant: .warning)
            } else if isLiveUpdatingTranscript {
                PillBadge(text: "Live transcript", systemImage: "waveform", variant: .accent)
            } else if isRecordingInProgress {
                PillBadge(text: "Recording", systemImage: "record.circle", variant: .danger)
            } else if isFinalizingTranscription {
                PillBadge(text: "Finalizing", systemImage: "waveform", variant: .accent)
            } else if isAwaitingTranscription {
                PillBadge(text: "Queued", systemImage: "clock.arrow.circlepath", variant: .warning)
            } else if isRemoteTranscribing {
                PillBadge(text: "Another device", systemImage: "laptopcomputer.and.iphone", variant: .info)
            } else if shouldShowPendingState {
                PillBadge(text: "Pending", systemImage: "clock.arrow.circlepath", variant: .warning)
            } else if !note.transcription.isEmpty {
                PillBadge(text: "Transcript", systemImage: "checkmark", variant: .success)
                PillBadge(
                    text: note.transcriptionModelDisplayName ?? "Model Unknown",
                    systemImage: note.transcriptionModelDisplayName == nil ? "questionmark.circle" : "cpu",
                    variant: note.transcriptionModelDisplayName == nil ? .neutral : .info
                )
                if let computeLabel = note.transcriptionComputeBadgeLabel {
                    PillBadge(text: computeLabel, systemImage: "cpu", variant: .info)
                }
                if let timeRatioLabel = note.averageProcessingTimeRatioLabel {
                    PillBadge(text: timeRatioLabel, systemImage: "timer", variant: .info)
                }
                if let speedLabel = note.averageTranscriptionSpeedLabel {
                    PillBadge(text: speedLabel, systemImage: "speedometer", variant: .info)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.metadata)
    }

    private var audioPlayerCard: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                WaveformBars(
                    seed: waveformSeed,
                    progress: waveformProgress,
                    levels: audioPlayer.waveformLevels,
                    activeTint: VoicelyTheme.accent,
                    inactiveTint: .secondary,
                    height: usesCompactDetailLayout ? 54 : 56,
                    onSeek: { ratio in
                        let target = ratio * max(audioPlayer.duration, 0)
                        audioPlayer.seek(to: target)
                    }
                )

                ZStack {
                    HStack {
                        Text(formatTime(audioPlayer.currentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .leading)

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            Text(formatTime(audioPlayer.duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            playbackRateButton
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    HStack(spacing: 18) {
                        transportButton(systemImage: "gobackward.15") {
                            audioPlayer.seekBackward(seconds: 15)
                        }
                        playButton
                        transportButton(systemImage: "goforward.15") {
                            audioPlayer.seekForward(seconds: 15)
                        }
                    }
                }
                .frame(height: 48)

                if audioPlayer.isPreparingAudio {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(audioPlayer.playbackStatusMessage ?? "Preparing audio…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let msg = audioPlayer.playbackStatusMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.audioPlayerCard)
    }

    private var waveformSeed: Int {
        WaveformSeedGenerator.stableSeed(for: note.id)
    }

    private var waveformProgress: Double {
        guard audioPlayer.duration > 0 else { return 0 }
        return min(max(audioPlayer.currentTime / audioPlayer.duration, 0), 1)
    }

    private var playButton: some View {
        Button(action: { audioPlayer.togglePlayPause() }) {
            Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.black)
                .frame(width: 48, height: 48)
                .background(Circle().fill(VoicelyTheme.accent))
                .shadow(color: VoicelyTheme.accent.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.playButton)
    }

    private var playbackRateButton: some View {
        Button(action: cyclePlaybackRate) {
            Text(String(format: "%.2g×", audioPlayer.playbackRate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(minWidth: 34)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(VoicelyTheme.surfaceRaised)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback Speed")
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.playbackRateButton)
    }

    private func transportButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.regular))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
    }

    private func cyclePlaybackRate() {
        let current = audioPlayer.playbackRate
        let next: Float
        if current < 1.0 - 0.01 { next = 1.0 }
        else if current < 1.5 - 0.01 { next = 1.5 }
        else if current < 2.0 - 0.01 { next = 2.0 }
        else { next = 1.0 }
        audioPlayer.setPlaybackRate(next)
    }

    private var transcriptionCard: some View {
        SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Transcription")
                        .font(.headline)
                    Spacer(minLength: 8)
                    transcriptionToolbar
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, retranscribeModelHint == nil ? 12 : 6)

                if let hint = retranscribeModelHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: shouldShowComputeTelemetry ? 12 : 0) {
                    if shouldShowComputeTelemetry {
                        computeTelemetryCard
                    }
                    transcriptionBody
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcriptionBody)
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcriptionCard)
    }

    @ViewBuilder
    private var transcriptionToolbar: some View {
        HStack(spacing: 6) {
            if !note.transcription.isEmpty {
                Button(action: copyTranscription) {
                    Image(systemName: copyConfirmVisible ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(copyConfirmVisible ? Color.green : .secondary)
                        .frame(width: 32, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy Transcript")
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.copyTranscriptionButton)

                Button(action: shareTranscription) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share Transcript")
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.shareTranscriptionButton)
            }

            if shouldShowTakeOverAction {
                retranscribeActionButton(title: "Take over", systemImage: "arrow.triangle.branch") {
                    requestTranscription(takeOver: true)
                }
            } else if note.transcription.isEmpty {
                if !shouldShowPrimaryTranscribeActionInBody && !isTranscribingHere {
                    retranscribeActionButton(title: "Transcribe", systemImage: "wand.and.stars") {
                        requestTranscription()
                    }
                }
            } else {
                retranscribeActionButton(title: "Re-transcribe", systemImage: "arrow.clockwise") {
                    showingRetranscribeConfirmation = true
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func retranscribeActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier(transcriptionActionIdentifier(for: title))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(transcriptionActionIdentifier(for: title))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(VoicelyTheme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(VoicelyTheme.hairline, lineWidth: 1)
            )
        }
        .accessibilityIdentifier(transcriptionActionIdentifier(for: title))
        .accessibilityLabel(title)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .buttonStyle(.plain)
        .disabled(note.audioFilePath.isEmpty || isTranscribingHere || isRemoteTranscribing)
    }

    private func transcriptionActionIdentifier(for title: String) -> String {
        switch title {
        case "Take over":
            return AccessibilityIdentifiers.Detail.takeOverTranscriptionButton
        case "Re-transcribe":
            return AccessibilityIdentifiers.Detail.retranscribeButton
        default:
            return AccessibilityIdentifiers.Detail.transcribeButton
        }
    }

    private var computeTelemetryCard: some View {
        let snapshot = currentTelemetrySnapshot
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "cpu")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VoicelyTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.computeRoute.summary)
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.computeRoute.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                PillBadge(
                    text: snapshot.isActive ? "Live" : "Selected",
                    systemImage: snapshot.isActive ? "bolt.fill" : "checkmark.circle",
                    variant: snapshot.isActive ? .accent : .neutral
                )
            }

            HStack(spacing: 8) {
                telemetryMetric(
                    title: "Model",
                    value: snapshot.modelName,
                    systemImage: "shippingbox"
                )
                telemetryMetric(
                    title: "Time ratio",
                    value: snapshot.metrics.processingTimeRatioLabel,
                    systemImage: "gauge.medium"
                )
                telemetryMetric(
                    title: "Speed",
                    value: snapshot.metrics.speedLabel,
                    systemImage: "speedometer"
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.caption)
                Text("Thermal \(snapshot.thermalStateLabel)")
                    .font(.caption)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Time ratio is processing time divided by audio duration.")
                    .font(.caption)
                    .lineLimit(2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous)
                .fill(VoicelyTheme.accentTint(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous)
                .stroke(VoicelyTheme.accentTint(0.20), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.computeTelemetryCard)
    }

    private func telemetryMetric(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VoicelyTheme.surfaceRaised)
        )
    }

    @ViewBuilder
    private var transcriptionBody: some View {
        if isLocallyTranscribing {
            VStack(alignment: .leading, spacing: 12) {
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
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.cancelTranscriptionButton)
            }
        } else if isRecordingPaused && !hasVisibleTranscript {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Recording paused")
                        .font(.subheadline.weight(.medium))
                }
                Text("Resume or stop the recording from the controls at the bottom of the screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if isRecordingInProgress && !hasVisibleTranscript {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recording…")
                        .font(.subheadline.weight(.medium))
                }
                Text("Waiting for the first live transcript segment. Keep speaking; text will appear here as soon as a segment finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if isFinalizingTranscription {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finalizing transcription…")
                        .font(.subheadline.weight(.medium))
                }
                Text("Finishing the recording and final transcription segment before saving the transcript.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if isAwaitingTranscription {
            VStack(alignment: .leading, spacing: 10) {
                PillBadge(text: "Queued for transcription", systemImage: "clock.arrow.circlepath", variant: .warning)
                Text("This note is waiting in the transcription queue and will switch to live progress once the local task starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: { requestTranscription() }) {
                    Label("Transcribe Now", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(VoicelyTheme.accent)
                .foregroundStyle(Color.black)
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcribeNowButton)
            }
        } else if isRemoteTranscribing {
            VStack(alignment: .leading, spacing: 10) {
                PillBadge(text: "Transcribing on another device", systemImage: "laptopcomputer.and.iphone", variant: .info)
                Text("This recording is currently being transcribed elsewhere. The transcript will appear here after sync finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if hasVisibleTranscript {
            if isLiveUpdatingTranscript {
                HStack(spacing: 8) {
                    if isRecordingPaused {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(isRecordingPaused ? "Recording paused" : "Recording — transcript updates live")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }

            if isEditing {
                TextEditor(text: $editedTranscription)
                    .font(.body)
                    .frame(minHeight: 220)
                    .padding(12)
                    .background(VoicelyTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcriptEditor)
            } else {
                Text(note.transcription)
                    .font(.body)
                    .lineSpacing(6)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcriptionBody)
            }
        } else if shouldShowPendingState {
            VStack(alignment: .leading, spacing: 10) {
                PillBadge(text: "Queued for transcription", systemImage: "clock.arrow.circlepath", variant: .warning)
                Text("This recording is waiting for transcription to start.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: { requestTranscription() }) {
                    Label("Transcribe Now", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(VoicelyTheme.accent)
                .foregroundStyle(Color.black)
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcribeNowButton)
            }
        } else if note.transcriptionOutcome == .noSpeech {
            VStack(alignment: .leading, spacing: 10) {
                PillBadge(text: "No speech", systemImage: "waveform.slash", variant: .neutral)
                Text("This recording is silence or background noise — nothing to transcribe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: { requestTranscription() }) {
                    Label("Transcribe again", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .tint(VoicelyTheme.accent)
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcribeNowButton)
            }
        } else if note.transcriptionOutcome == .failed {
            VStack(alignment: .leading, spacing: 10) {
                PillBadge(text: "Couldn't transcribe", systemImage: "arrow.clockwise", variant: .warning)
                Text("Something went wrong this time. Tap to try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: { requestTranscription() }) {
                    Label("Try again", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(VoicelyTheme.accent)
                .foregroundStyle(Color.black)
                .accessibilityIdentifier(AccessibilityIdentifiers.Detail.transcribeNowButton)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                PillBadge(text: "No transcript yet", systemImage: "text.badge.xmark", variant: .neutral)
                Text("Recordings without transcription can still be played back, renamed, and shared later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadAudioFile() {
        if shouldShowAudioPlayerCard {
            audioPlayer.loadAudio(from: note.audioFilePath, expectedDuration: note.duration)
        }
    }

    private func toggleEdit() {
        if isEditing {
            let titleChanged = editedTitle != note.title
            note.title = editedTitle
            if titleChanged, !editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note.titleWasManuallyEdited = true
            }
            note.transcription = editedTranscription
            if editedTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note.transcriptionModelIdentifier = nil
            }
        } else {
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
        copyConfirmVisible = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copyConfirmVisible = false
        }
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
            let didStart = await transcriptionService.requestTranscription(
                for: note,
                force: force,
                takeOver: takeOver
            )
            if didStart, !isEditing {
                editedTranscription = note.transcription
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

    private func cancelCurrentTranscription() {
        transcriptionService.cancelTranscription(for: note)
    }
}

// MARK: - Supporting layouts and components

struct WrappingFlowLayout: Layout {
    struct Item {
        let index: Int
        let frame: CGRect
    }

    struct Cache {
        var items: [Item] = []
        var size: CGSize = .zero
        var maxWidth: CGFloat?
        var subviewCount = 0
    }

    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> Cache {
        Cache(subviewCount: subviews.count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        updateCache(for: subviews, maxWidth: proposal.width ?? .greatestFiniteMagnitude, cache: &cache)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        updateCache(for: subviews, maxWidth: bounds.width, cache: &cache)
        for item in cache.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                proposal: ProposedViewSize(item.frame.size)
            )
        }
    }

    private func updateCache(for subviews: Subviews, maxWidth: CGFloat, cache: inout Cache) {
        if cache.maxWidth == maxWidth, cache.subviewCount == subviews.count {
            return
        }
        let layout = makeLayout(for: subviews, maxWidth: maxWidth)
        cache.items = layout.items
        cache.size = layout.size
        cache.maxWidth = maxWidth
        cache.subviewCount = subviews.count
    }

    private func makeLayout(for subviews: Subviews, maxWidth: CGFloat) -> (items: [Item], size: CGSize) {
        let availableWidth = max(maxWidth, 0)
        var items: [Item] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var layoutWidth: CGFloat = 0
        var layoutHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > availableWidth {
                currentX = 0
                currentY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: currentX, y: currentY), size: size)
            items.append(Item(index: index, frame: frame))
            layoutWidth = max(layoutWidth, frame.maxX)
            layoutHeight = max(layoutHeight, frame.maxY)
            currentX += size.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        return (items, CGSize(width: layoutWidth, height: layoutHeight))
    }
}

struct SyncStatusBannerCard: View {
    let description: String
    let tint: Color
    let showsRetry: Bool
    let retryAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
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
                    .tint(tint)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

struct EmptyLibraryCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor.opacity(0.55))
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(VoicelyTheme.surface)
                )
            Text("No Recordings Yet")
                .font(.headline)
            Text("Tap the microphone to create your first voice note.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct DetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(VoicelyTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(VoicelyTheme.hairline, lineWidth: 1)
                )
            VStack(spacing: 4) {
                Text("Select a recording")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Choose a note or start a new recording.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.detailPlaceholder)
    }
}

struct AudioWaveformView: View {
    let isAnimating: Bool
    // Not @ObservedObject: the level is pulled from the audio-thread lock at
    // the TimelineView cadence, so service publishes don't re-render this view.
    let audioService: AudioRecordingService
    @State private var waveHeights: [CGFloat] = Array(repeating: 0.2, count: 22)
    @State private var smoothedLevel: Float = 0

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.animation(minimumInterval: 0.08)) { timeline in
                    barsView
                        .onChange(of: timeline.date) { _, _ in
                            updateWaveHeights()
                        }
                }
            } else {
                barsView
            }
        }
    }

    private var barsView: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<waveHeights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.red.opacity(0.72))
                    .frame(width: 2)
                    .scaleEffect(y: waveHeights[index], anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateWaveHeights() {
        let normalised = min(Float(1.0), audioService.peekAudioLevel() * 10)
        var smoothed = smoothedLevel * 0.3 + normalised * 0.7
        if smoothed < 0.04 { smoothed = 0 }
        smoothedLevel = smoothed

        var newHeights = waveHeights
        newHeights.removeFirst()
        let base = CGFloat(max(0, min(1, smoothed)))
        let adjusted = pow(base, 0.6)
        let variation = CGFloat.random(in: 0.85...1.1)
        let level = adjusted * variation
        let minH: CGFloat = 0.2
        let maxH: CGFloat = 1.35
        let newH = minH + (maxH - minH) * level
        newHeights.append(max(minH, min(maxH, newH)))
        waveHeights = newHeights
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ShareSheet>) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems, applicationActivities: applicationActivities)
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
