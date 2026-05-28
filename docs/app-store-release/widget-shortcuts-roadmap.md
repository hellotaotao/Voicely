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

## Current Priority

Tao's current priority is to make Voicely feel like an iOS system-level meeting recorder before changing the main recording UI:

1. Live Activity / Dynamic Island recording status first.
2. App Shortcut / Action Button quick start first.
3. Timed recording next, because it needs more visible app UI decisions.
4. Apple Watch later, because it adds watchOS and cross-device complexity for less immediate value.

## Recommended Phases

## Phase 1 — Recording System Integration

### Live Activity: Active Recording Status

Behavior:

- Starts a Recording Live Activity when Voicely starts recording.
- Shows “Voicely is recording” and elapsed recording time on the Lock Screen and Dynamic Island.
- Ends the Live Activity when recording stops.
- Keeps the Activity content state ready for a future `scheduledEndDate`, so timed recording can add remaining-time display without replacing the model.

Implementation direction:

- Use `ActivityKit` from the app and a `WidgetKit` extension for the Lock Screen / Dynamic Island UI.
- Use system timer rendering for elapsed time instead of manually updating every second.
- Treat Live Activity as display only; recording control remains in `AudioRecordingService` / `RecordingControls`.

### Shortcut: Start Recording

Behavior:

- Supports `voicely://record`.
- Adds `StartRecordingIntent` and App Shortcuts phrases such as “Start a Voicely recording”.
- Opens Voicely directly into a visible recording flow.
- Does not silently record without clear user-visible app state.

Action Button direction:

- Treat iPhone Action Button support as an extension of this shortcut, not a separate recording engine.
- Users should be able to assign the Voicely start-recording shortcut to Action Button long press where iOS supports that workflow.

### Later App Shortcuts

- `OpenLatestTranscriptIntent`: open the most recent `VoiceNote` with non-empty transcription.
- `CopyLatestTranscriptIntent`: copy only after privacy-safe confirmation.
- `TranscribePendingRecordingsIntent`: open the app and reuse `TranscriptionService.processPendingTranscriptions`.

### Phase 1 Acceptance Criteria

- Live Activity appears while recording and disappears when recording stops.
- Dynamic Island compact/minimal/expanded states clearly indicate active recording.
- Shortcuts appear in iOS Shortcuts app.
- The Start Recording shortcut can be assigned to Action Button where iOS supports that workflow.
- The shortcut and `voicely://record` route open Voicely into visible recording state instead of recording invisibly.
- No recording logic is duplicated across app, intents, and widgets.

## Phase 2 — Timed Recording

Timed recording is next because it is important, but it changes the start-recording and in-recording UI.

Behavior:

- Let the start-recording flow optionally accept a target duration, such as 30, 35, 41, or 60 minutes.
- Show a prominent countdown warning a few minutes before auto-stop, with choices to extend or stop.
- Show remaining time in the app and the Recording Live Activity when a target duration exists.
- Consider a later smart-stop layer that detects farewell phrases plus sustained silence near the scheduled end time before stopping automatically.

Implementation direction:

- Extend `RecordingActivityAttributes.ContentState.scheduledEndDate` rather than introducing a new Live Activity model.
- Keep auto-stop scheduling in the app recording flow, not in the widget extension.

## Phase 3 — Lock Screen / Home Screen Widgets

Non-Live-Activity widgets should show status and quick entry points, not sensitive transcript text by default.

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

### Phase 3 Acceptance Criteria

- Widgets do not leak sensitive transcript text on Lock Screen by default.
- Widget state updates after recording/transcription/sync changes.
- Widget works when iCloud is unavailable.
- Widget tap/deep link opens correct app state.

## Phase 4 — Share Sheet / Import Audio

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

## Phase 5 — Advanced AppIntents

Only after Phases 1–4 are stable.

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

- Metadata bullet: “See active recording status on the Lock Screen and start recordings from Shortcuts.”
- Screenshot candidate: “Recording on Lock Screen / Dynamic Island” only after device verification.
- Review notes: mention widgets/shortcuts do not record silently; recording remains user initiated and visible.
- Privacy notes: widgets expose status only by default, not transcript text.

Do not add these claims to the live listing until the feature ships.

## Recently Implemented Slice

The first system-integration slice is now represented in code:

1. `voicely://record` deep-link route.
2. `StartRecordingIntent` / App Shortcuts metadata for visible start-recording flow.
3. Recording Live Activity model, controller, and WidgetKit extension.
4. Timed recording remains the next major product feature.

Manual device verification is still needed for Lock Screen, Dynamic Island, and Action Button assignment behavior.
