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
        
        // Check if user wants to preload model on startup
        let preloadOnStartup = UserDefaults.standard.bool(forKey: "preloadModelOnStartup")
        if preloadOnStartup && !transcriptionService.isWhisperAvailable() {
            let _ = await transcriptionService.loadWhisperModel()
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
                HStack(spacing: 16) {
                    Button(action: stopRecording) {
                        Image(systemName: "stop.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    
                    VStack(spacing: 8) {
                        AudioWaveformView(
                            isAnimating: $waveformAnimation,
                            audioService: audioService
                        )
                        .frame(width: 180, height: 30)
                        
                        Text(formatDuration(audioService.recordingDuration))
                            .font(.title2)
                            .monospacedDigit()
                            .foregroundColor(.primary)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    if isModelLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(modelLoadingMessage)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        }
                    } else if !isModelLoaded && !(transcriptionService.modelManager?.isSelectedModelDownloaded() ?? true) {
                        Text(modelLoadingMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                    
                    Button(action: startRecording) {
                        Image(systemName: "mic.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(audioService.hasPermission ? Color.blue : Color.gray)
                            .clipShape(Circle())
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
        // Load model if not already loaded (lazy loading)
        if !transcriptionService.isWhisperAvailable() {
            Task {
                await transcriptionService.loadWhisperModel()
            }
        }
        
        currentRecordingPath = audioService.startRecording()
        waveformAnimation = true
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
                HStack {
                    VStack(alignment: .leading) {
                        Text(note.title)
                            .font(.title2)
                            .bold()
                        
                        Text(note.timestamp, format: Date.FormatStyle(date: .complete, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(formatDuration(note.duration))
                        .font(.headline)
                        .foregroundColor(.secondary)
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
                        Text("Transcription")
                            .font(.headline)
                        
                        Text(note.transcription)
                            .font(.body)
                            .textSelection(.enabled)
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

#Preview {
    ContentView()
        .modelContainer(for: VoiceNote.self, inMemory: true)
}
