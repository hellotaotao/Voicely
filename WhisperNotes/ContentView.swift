//
//  ContentView.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VoiceNote.timestamp, order: .reverse) private var voiceNotes: [VoiceNote]
    @StateObject private var audioService = AudioRecordingService()
    @StateObject private var transcriptionService = TranscriptionService()
    @State private var selectedNote: VoiceNote?
    
    var body: some View {
        NavigationSplitView {
            VStack {
                List {
                    ForEach(voiceNotes) { note in
                        VoiceNoteRow(note: note)
                            .onTapGesture {
                                selectedNote = note
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
        } detail: {
            if let selectedNote = selectedNote {
                VoiceNoteDetailView(note: selectedNote)
            } else {
                Text("Select a voice note")
                    .foregroundColor(.secondary)
            }
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
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
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
    
    var body: some View {
        VStack(spacing: 16) {
            if audioService.isRecording {
                VStack(spacing: 8) {
                    Text("Recording...")
                        .font(.headline)
                        .foregroundColor(.red)
                    
                    Text(formatDuration(audioService.recordingDuration))
                        .font(.title2)
                        .monospacedDigit()
                    
                    Button(action: stopRecording) {
                        Image(systemName: "stop.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                }
            } else {
                Button(action: startRecording) {
                    Image(systemName: "mic.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(audioService.hasPermission ? Color.blue : Color.gray)
                        .clipShape(Circle())
                }
                .disabled(!audioService.hasPermission)
                
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
        currentRecordingPath = audioService.startRecording()
    }
    
    private func stopRecording() {
        let (filePath, duration) = audioService.stopRecording()
        
        guard let filePath = filePath else { return }
        
        let note = VoiceNote(
            title: "Voice Note \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))",
            audioFilePath: filePath
        )
        note.duration = duration
        note.isTranscribing = true
        
        onRecordingComplete(note)
        
        Task {
            let transcription = await transcriptionService.transcribeAudio(filePath: filePath)
            await MainActor.run {
                note.transcription = transcription
                note.isTranscribing = false
            }
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
                
                if note.isTranscribing {
                    HStack {
                        ProgressView()
                        Text("Transcribing audio...")
                            .foregroundColor(.secondary)
                    }
                } else if !note.transcription.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcription")
                            .font(.headline)
                        
                        Text(note.transcription)
                            .font(.body)
                            .textSelection(.enabled)
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
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: duration) ?? "0 seconds"
    }
}

#Preview {
    ContentView()
        .modelContainer(for: VoiceNote.self, inMemory: true)
}
