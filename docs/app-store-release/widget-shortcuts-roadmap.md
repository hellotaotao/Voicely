# Voicely Widgets and Shortcuts Roadmap

> Planning only. Do not implement until the product owner approves a specific phase.

## Goal

Extend Voicely beyond the main app with lightweight system entry points that reinforce the core positioning: local-first transcription for sensitive meetings. Widgets and Shortcuts should help users start, find, and reuse meeting transcripts faster without turning Voicely into a generic quick memo app.

## Current Codebase Baseline

- Current app target has no `WidgetKit`, `AppIntents`, `Intents`, `Shortcuts`, `WidgetBundle`, or extension code found by static search.
- Core data model is SwiftData `VoiceNote` in `Voicely/Item.swift` with fields including title, timestamp, duration, audio path, transcription, transcription state/progress, model identifier, pending transcription, and ownership/lease metadata.
- Main app already has recording controls in `Voicely/ContentView.swift`, transcription actions, copy/share, re-transcribe, delete note/audio, and CloudKit/iCloud support.
- Local transcription is implemented through `Voicely/TranscriptionService.swift` using WhisperKit/CoreML.
- Audio and iCloud storage are handled through `Voicely/AudioRecordingService.swift`, `Voicely/AudioPlayerService.swift`, and `Voicely/CloudStorageManager.swift`.

## Product Principle

Do not copy Noted feature-for-feature. Noted is a mature recording notebook with widgets, AppIntents, tags, notebooks, reminders, and screen recording. Voicely should start narrower:

1. Sensitive meeting capture.
2. Local/on-device transcription status.
3. Review and export transcript.
4. User-controlled retention.

Widgets and Shortcuts should support those jobs, not distract with generic note-taking breadth.

## Recommended Phases

## Phase 1 — App Shortcuts First

This is the highest leverage because it improves system integration with limited UI surface area.

### Shortcut 1: Start Recording

User phrase examples:

- “Start a Voicely recording”
- “Record a sensitive meeting in Voicely”

Behavior:

- Opens Voicely directly into the recording flow.
- If recording cannot start from the background due to iOS privacy/audio restrictions, open the app and focus the primary record control.
- Do not silently record without clear user-visible app state.

Implementation direction:

- Add an `AppIntent` such as `StartRecordingIntent`.
- Use app navigation/deep-link state rather than duplicating recording logic inside the intent.
- Keep microphone permission onboarding in the app.

### Shortcut 2: Open Latest Transcript

User phrase examples:

- “Open my latest Voicely transcript”
- “Show last meeting transcript”

Behavior:

- Opens the most recent `VoiceNote` with non-empty transcription.
- If none exist, opens the library and shows an empty/help state.

Implementation direction:

- Query SwiftData for latest transcribed note in app context.
- Deep link to selected note ID.

### Shortcut 3: Copy Latest Transcript

User phrase examples:

- “Copy latest Voicely transcript”

Behavior:

- Copies latest transcript to the clipboard, or opens app with a clear message if locked/no transcript.
- This should require user confirmation if privacy risk is high.

Implementation direction:

- Prefer opening the app to a confirmation screen first for sensitive content.
- Avoid exposing transcript contents in Siri spoken output.

### Shortcut 4: Transcribe Pending Recordings

User phrase examples:

- “Transcribe pending Voicely recordings”

Behavior:

- Opens the app and starts processing queued pending transcriptions on the eligible device.
- If no model is loaded, routes to model settings.

Implementation direction:

- Reuse existing `TranscriptionService.processPendingTranscriptions` style flow.
- Do not run heavy transcription inside the intent process.

### Phase 1 Acceptance Criteria

- Shortcuts appear in iOS Shortcuts app.
- Each shortcut has privacy-safe wording.
- No shortcut silently exposes sensitive transcript content.
- No transcription or recording logic is duplicated across app and intents.
- App opens to the right state from each shortcut.

## Phase 2 — Lock Screen / Home Screen Widgets

Widgets should show status and quick entry points, not sensitive transcript text by default.

### Widget 1: Recording / Transcription Status

Purpose:

- Show whether there are pending or completed local transcripts.
- Encourage review without exposing meeting content.

Possible display:

- “2 recordings waiting for local transcription”
- “Latest transcript ready”
- “Model not loaded”
- “iCloud sync pending”

Privacy rule:

- Default widget must not show transcript text or meeting titles unless the user explicitly enables a less-private mode.

Implementation direction:

- Add a Widget extension target.
- Share lightweight state through an App Group, not by directly reading full SwiftData/iCloud state from the widget.
- Create a small `WidgetSnapshot` JSON written by the main app: counts, latest status, last updated, no raw transcript.

### Widget 2: Quick Record Launcher

Purpose:

- One tap opens Voicely ready to record.

Possible surfaces:

- Home Screen widget button.
- Lock Screen widget.
- Control-style entry if supported by current iOS target.

Implementation direction:

- Use deep links such as `voicely://record` or AppIntent-driven widget actions.
- The widget should launch the app rather than recording invisibly.

### Widget 3: Review Latest Transcript

Purpose:

- Quickly jump to latest completed transcript.

Privacy rule:

- Show “Latest transcript ready” rather than the actual content.

Implementation direction:

- Deep link to latest transcribed note ID if available.
- If note ID cannot be safely shared, open the app library filtered to completed transcripts.

### Phase 2 Acceptance Criteria

- Widgets do not leak sensitive transcript text on Lock Screen by default.
- Widget state updates after recording/transcription/sync changes.
- Widget works when iCloud is unavailable.
- Widget tap/deep link opens correct app state.

## Phase 3 — Share Sheet / Import Audio

This is already listed in `AGENTS.md` as a TODO and is important for real workflows.

User job:

- Import a meeting audio file from Files, Voice Memos, Mail, Slack, Teams, or another app.
- Create a `VoiceNote` and optionally queue local transcription.

Implementation direction:

- Register audio file UTIs in `Info.plist`.
- Handle inbound file URLs in app lifecycle.
- Copy imported file into Voicely storage through `CloudStorageManager`.
- Create a `VoiceNote` with source metadata.
- Offer “Transcribe locally now” after import if a model is loaded.

Acceptance criteria:

- User can share/open an audio file into Voicely.
- Imported audio is copied into app-controlled storage.
- Original file remains untouched.
- Transcription uses same local WhisperKit flow.

## Phase 4 — Advanced AppIntents

Only after Phases 1–3 are stable.

Candidates:

- `FindTranscriptIntent`: search local transcripts by title/date/query.
- `ExportTranscriptIntent`: export selected transcript as plain text/Markdown.
- `DeleteRecordingAudioIntent`: keep transcript but remove raw audio after confirmation, if product supports transcript-only retention.
- `CreateMeetingNoteIntent`: create a blank planned meeting note before recording.

Caution:

- Anything that deletes audio or exposes transcript content should require explicit confirmation and strong privacy-safe UI.

## Technical Architecture Recommendation

### Add a small navigation/deep-link layer first

Before widgets/shortcuts, define app routes:

- `voicely://record`
- `voicely://latest-transcript`
- `voicely://note/<uuid>`
- `voicely://pending-transcriptions`
- `voicely://settings/models`

This prevents widgets and shortcuts from knowing too much about view internals.

### Add shared state carefully

For widgets:

- Use App Group storage for a minimal status snapshot.
- Do not share raw transcripts/audio by default.
- Main app writes snapshot whenever notes/transcription/sync state changes.
- Widget reads snapshot and deep-links back to app.

### Keep heavy work in the app

Do not run recording or WhisperKit transcription inside widget/intent extension processes. Use intents/widgets to launch or route the user into the main app.

## App Store / Marketing Impact

Once Phase 1 or Phase 2 exists, update App Store assets:

- Metadata bullet: “Start recordings and reopen transcripts from Shortcuts and widgets.”
- Screenshot candidate: “Start from Lock Screen or Shortcuts” only after implemented.
- Review notes: mention widgets/shortcuts do not record silently; recording remains user initiated and visible.
- Privacy notes: widgets expose status only by default, not transcript text.

Do not add these claims to the live listing until the feature ships.

## Recommended First Implementation Slice

If implementing next, start with this exact slice:

1. Add URL/deep-link route handling for `voicely://record` and `voicely://latest-transcript`.
2. Add AppIntent `StartRecordingIntent` that opens `voicely://record`.
3. Add AppIntent `OpenLatestTranscriptIntent` that opens `voicely://latest-transcript`.
4. Add tests or manual verification around routing state.
5. Only then add the first widget.

Reason: shortcuts become useful quickly, and the same route layer supports later widgets.
