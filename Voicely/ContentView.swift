//
//  ContentView.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VoiceNote.timestamp, order: .reverse) private var voiceNotes: [VoiceNote]
    @StateObject private var audioService = AudioRecordingService()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var transcriptionService = TranscriptionService()
    @State private var selectedNote: VoiceNote?
    @State private var showingSettings = false
    
    var body: some View {
        NavigationSplitView {
            VStack {
                List {
                    ForEach(voiceNotes) { note in
                        NavigationLink(destination: VoiceNoteDetailView(note: note).environmentObject(transcriptionService)) {
                            VoiceNoteRow(note: note)
                        }
                        .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: deleteNotes)
                }
                
                RecordingControls(
                    audioService: audioService,
                    transcriptionService: transcriptionService,
                    onRecordingComplete: { note in
                        modelContext.insert(note)
                    }
                )
            }
            .navigationTitle("Voice Notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(modelManager)
            }
            .task {
                await setupServices()
            }
        } detail: {
            if let selectedNote = selectedNote {
                VoiceNoteDetailView(note: selectedNote)
                    .environmentObject(transcriptionService)
            } else {
                Text("Select a voice note")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func setupServices() async {
        transcriptionService.setModelManager(modelManager)
        await modelManager.fetchModels()
        
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
    
    private func deleteNotes(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let note = voiceNotes[index]
                // Delete audio file
                if !note.audioFilePath.isEmpty {
                    try? FileManager.default.removeItem(atPath: note.audioFilePath)
                }
                modelContext.delete(note)
            }
        }
    }
}

struct VoiceNoteRow: View {
    let note: VoiceNote
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.title)
                    .font(.headline)
                Spacer()
                Text(formatDuration(note.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(note.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundColor(.secondary)
            
            if !note.transcription.isEmpty {
                Text(note.transcription)
                    .font(.body)
                    .lineLimit(3)
            } else if note.isTranscribing {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Transcribing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(note.transcriptionProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ProgressView(value: note.transcriptionProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .scaleEffect(y: 0.5)
                }
            } else if note.pendingTranscription {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.orange)
                    Text("Waiting for model to load")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "0s"
    }
}

struct RecordingControls: View {
    @ObservedObject var audioService: AudioRecordingService
    @ObservedObject var transcriptionService: TranscriptionService
    let onRecordingComplete: (VoiceNote) -> Void
    
    @State private var currentRecordingPath: String?
    @State private var waveformAnimation = false
    
    // Computed properties to check model state
    private var isModelLoading: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loading || 
               modelManager.modelState == .downloading || 
               modelManager.modelState == .prewarming
    }
    
    private var isModelLoaded: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loaded
    }
    
    private var modelLoadingMessage: String {
        guard let modelManager = transcriptionService.modelManager else { return "Model not available" }
        switch modelManager.modelState {
        case .loading:
            return "Loading model..."
        case .downloading:
            return "Downloading model (\(Int(modelManager.loadingProgressValue * 100))%)..."
        case .prewarming:
            return "Optimizing model..."
        case .unloaded:
            if modelManager.isSelectedModelDownloaded() {
                return "Ready to record"
            } else {
                return "Model needs download"
            }
        case .loaded:
            return ""
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            if audioService.isRecording {
                // Recording layout: waveform on left, button in center, time on right
                HStack(spacing: 16) {
                    // Left side - Waveform
                    AudioWaveformView(
                        isAnimating: $waveformAnimation,
                        audioService: audioService
                    )
                    .frame(width: 80, height: 30)
                    .onChange(of: audioService.isPaused) { _, isPaused in
                        waveformAnimation = !isPaused
                    }
                    
                    // Center - Stop button (same position as start button)
                    Button(action: stopRecording) {
                        Image(systemName: "stop.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    
                    // Right side - Recording time and pause button
                    VStack(spacing: 4) {
                        Text(formatDuration(audioService.recordingDuration))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundColor(.primary)
                        
                        Button(action: togglePauseResume) {
                            Image(systemName: audioService.isPaused ? "play.fill" : "pause.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .frame(width: 30, height: 30)
                                .background(audioService.isPaused ? Color.green : Color.orange)
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .frame(width: 80)
                }
            } else {
                VStack(spacing: 8) {
                    // Center - Start button with optional loading indicator
                    Button(action: startRecording) {
                        ZStack {
                            Image(systemName: "mic.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .frame(width: 60, height: 60)
                                .background(audioService.hasPermission ? Color.blue : Color.gray)
                                .clipShape(Circle())
                            
                            // Small orange dot indicator when model is loading
                            if isModelLoading {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                    .offset(x: -20, y: 0)
                            }
                        }
                    }
                    .disabled(!audioService.hasPermission)
                }
                
                if !audioService.hasPermission {
                    Text("Microphone permission required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding()
    }
    
    private func startRecording() {
        // Start recording immediately - model should already be loaded or loading
        currentRecordingPath = audioService.startRecording()
        waveformAnimation = true
    }
    
    private func togglePauseResume() {
        if audioService.isPaused {
            audioService.resumeRecording()
            waveformAnimation = true
        } else {
            audioService.pauseRecording()
            waveformAnimation = false
        }
    }
    
    private func stopRecording() {
        waveformAnimation = false
        let (filePath, duration) = audioService.stopRecording()
        
        guard let filePath = filePath else { return }
        
        let note = VoiceNote(
            title: "Voice Note \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))",
            audioFilePath: filePath
        )
        note.duration = duration
        
        // Check if model is loaded
        if isModelLoaded {
            note.isTranscribing = true
            
            onRecordingComplete(note)
            
            Task {
                let transcription = await transcriptionService.transcribeAudio(filePath: filePath) { progress in
                    Task { @MainActor in
                        note.transcriptionProgress = progress
                    }
                }
                
                await MainActor.run {
                    if let transcription = transcription {
                        note.transcription = transcription
                    } else {
                        note.transcription = ""
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
            VStack(alignment: .leading, spacing: 16) {
                // Title and Edit Button
                HStack {
                    if isEditing {
                        TextField("Note title", text: $editedTitle)
                            .font(.title2)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        VStack(alignment: .leading) {
                            Text(note.title)
                                .font(.title2)
                                .bold()
                            
                            Text(note.timestamp, format: Date.FormatStyle(date: .complete, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: toggleEdit) {
                        Text(isEditing ? "Done" : "Edit")
                            .foregroundColor(.blue)
                    }
                }
                
                // Duration
                HStack {
                    Text("Duration: ")
                        .foregroundColor(.secondary)
                    Text(formatDuration(note.duration))
                        .font(.headline)
                }
                
                Divider()
                
                // Audio Player Controls - Compact Design
                if !note.audioFilePath.isEmpty {
                    VStack(spacing: 12) {
                        // Progress Bar
                        VStack(spacing: 4) {
                            ProgressView(value: audioPlayer.currentTime, total: audioPlayer.duration)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(height: 4)
                            
                            HStack {
                                Text(formatTime(audioPlayer.currentTime))
                                    .font(.caption)
                                    .monospacedDigit()
                                Spacer()
                                Text(formatTime(audioPlayer.duration))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                        
                        // Control Buttons centered with speed on the right
                        HStack {
                            Spacer()
                            
                            HStack(spacing: 20) {
                                // Backward 5 seconds
                                Button(action: { audioPlayer.seekBackward() }) {
                                    Image(systemName: "gobackward.5")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                // Play/Pause
                                Button(action: { audioPlayer.togglePlayPause() }) {
                                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 44))
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                // Forward 5 seconds
                                Button(action: { audioPlayer.seekForward() }) {
                                    Image(systemName: "goforward.5")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            
                            Spacer()
                            
                            // Compact Speed Control - positioned absolutely on the right
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
                                HStack(spacing: 4) {
                                    Text(String(format: "%.2gx", audioPlayer.playbackRate))
                                        .font(.footnote)
                                        .foregroundColor(.blue)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.systemGray5))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                
                Divider()
                
                if note.isTranscribing || isTranscribing {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ProgressView()
                            Text("Transcribing audio...")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(note.transcriptionProgress * 100))%")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        
                        ProgressView(value: note.transcriptionProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(height: 8)
                    }
                } else if !note.transcription.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transcription")
                                .font(.headline)
                            
                            Spacer()
                            
                            HStack(spacing: 12) {
                                Button(action: { copyTranscription() }) {
                                    Image(systemName: "square.on.square")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                Button(action: { shareTranscription() }) {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        
                        if isEditing {
                            TextEditor(text: $editedTranscription)
                                .font(.body)
                                .frame(minHeight: 200)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        } else {
                            Text(note.transcription)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                } else if note.pendingTranscription {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Transcription pending")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        Text("This recording needs to be transcribed")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        if isModelLoaded {
                            Button(action: transcribeAudio) {
                                Label("Transcribe Now", systemImage: "wand.and.stars")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .padding(.top, 8)
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("Please load a model in Settings first")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 8)
                        }
                    }
                } else {
                    Text("No transcription available")
                        .foregroundColor(.secondary)
                        .italic()
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [note.transcription])
        }
        .onChange(of: modelLoadingState) { oldValue, newValue in
            if newValue == .loaded && note.pendingTranscription {
                // Model just loaded and note needs transcription
                transcribeAudio()
            }
        }
        .alert("Model Not Loaded", isPresented: $showLoadModelPrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Go to Settings") {
                // Logic to open settings in detail view needs to be implemented
            }
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
        UIPasteboard.general.string = note.transcription
    }
    
    private func shareTranscription() {
        showingShareSheet = true
    }
    
    private func transcribeAudio() {
        guard isModelLoaded, note.pendingTranscription, !note.audioFilePath.isEmpty else { return }
        
        isTranscribing = true
        note.isTranscribing = true
        
        Task {
            let transcription = await transcriptionService.transcribeAudio(filePath: note.audioFilePath) { progress in
                Task { @MainActor in
                    note.transcriptionProgress = progress
                }
            }
            
            await MainActor.run {
                isTranscribing = false
                note.isTranscribing = false
                
                if let transcription = transcription {
                    note.transcription = transcription
                    note.pendingTranscription = false
                } else {
                    note.transcriptionProgress = 0.0
                    // Keep pendingTranscription as true since we failed
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: duration) ?? "0 seconds"
    }
}

// Replace custom waveform implementation with WaveformData-driven view
struct AudioWaveformView: View {
    @Binding var isAnimating: Bool
    @ObservedObject var audioService: AudioRecordingService
    @State private var waveHeights: [CGFloat] = Array(repeating: 0.2, count: 18)
    
    var body: some View {
        if isAnimating {
            TimelineView(.animation(minimumInterval: 0.05)) { timeline in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<18, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.blue)
                            .frame(width: 2.5)
                            .scaleEffect(y: waveHeights[index], anchor: .center)
                            .animation(.easeInOut(duration: 0.05), value: waveHeights[index])
                    }
                }
                .frame(height: 30)
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
                        .fill(Color.blue)
                        .frame(width: 2.5)
                        .scaleEffect(y: 0.2, anchor: .center)
                }
            }
            .frame(height: 30)
        }
    }
    
    private func updateWaveHeights() {
        // Create new array
        var newHeights = waveHeights
        // Shift left
        newHeights.removeFirst()
        // Compute new height based on current audio level
        let base = CGFloat(max(0, min(1, audioService.audioLevel)))
        let adjusted = pow(base, 0.6)
        let variation = CGFloat.random(in: 0.9...1.1)
        let level = adjusted * variation
        let minH: CGFloat = 0.15  // Slightly lower minimum
        let maxH: CGFloat = 1.2   // Slightly higher maximum
        let newH = minH + (maxH - minH) * level
        newHeights.append(max(minH, min(maxH, newH)))
        // Update state
        waveHeights = newHeights
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: UIViewControllerRepresentableContext<ShareSheet>) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        
        // For iPad and Mac Catalyst, we need to configure the popover presentation
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView()
            popover.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ShareSheet>) {}
}

#Preview {
    ContentView()
        .modelContainer(for: VoiceNote.self, inMemory: true)
}
