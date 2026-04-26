# Screenshot Plan

Goal: tell a privacy-conscious professional story, not a generic voice memo story. Use synthetic meeting names and transcript text. Do not screenshot real sensitive meetings.

## 6.7-Inch iPhone Narrative

Use 5-6 screenshots. Recommended set: 6 screenshots on a 6.7-inch iPhone simulator/device, with consistent status bar and a clean light-mode UI unless the final brand direction prefers dark mode.

| # | Screen/state | Exact overlay caption | Capture notes |
| --- | --- | --- | --- |
| 1 | Library with a sensitive but synthetic meeting note selected, for example "Vendor Risk Review" | "Sensitive meetings, captured local-first" | Show Voicely as a professional meeting record system. Avoid empty-state positioning. |
| 2 | Active recording screen with waveform/timer and model rail visible | "Record meeting-length audio on iPhone" | Use a realistic elapsed time, not just a few seconds. Keep the red/recording state visible. |
| 3 | Detail screen while local transcription is running | "Transcribe with WhisperKit on device" | Show progress UI and the note status. Do not imply that model download is unnecessary. |
| 4 | Completed transcript detail screen | "Review and edit the transcript" | Show readable transcript text, model badge, playback controls, and the Edit button. |
| 5 | Transcript actions plus list/delete affordance or Share Sheet entry point | "Keep, delete, copy, or share" | Show copy/share buttons and a context where deletion is visible or easy to infer. If using Share Sheet, keep personal destinations hidden. |
| 6 | Settings model management/language/compute screen, optionally with iCloud sync indicator shown elsewhere | "Control models, language, and iCloud" | Show Model Status, Available Models, Language Settings, and Compute Settings. If iCloud sync is active, capture the iCloud status indicator/action sheet as an alternate shot. |

## Visual Direction

- The screenshots should look like an internal/professional tool for sensitive meetings.
- Use realistic enterprise-facing sample content: "Board prep", "Legal intake", "HR policy review", "Client strategy session".
- Keep captions short and benefit-led.
- Avoid claims such as "compliant", "certified", "zero cloud", or "never syncs". Current code supports iCloud/CloudKit sync and model downloads.
- If captions are added outside the app UI, keep them consistent, high contrast, and away from the app navigation bar and action buttons.

## Optional 6.5-Inch Adaptation

- Reuse the same six-shot story.
- Re-capture rather than crop if text or buttons become cramped.
- Keep overlay captions identical unless App Store Connect size constraints require shorter text.
- Confirm current App Store Connect screenshot-size requirements before upload.

## Optional iPad Adaptation

- Use iPad screenshots only if the final App Store listing targets iPad screenshots for this release.
- Lean into the split-view layout: library on the left, selected transcript detail on the right.
- Suggested iPad captions:
  - "Meeting library and transcript side by side"
  - "Review audio and transcript together"
  - "Manage local models for each device"
- Avoid using iPad screenshots that make the product look like a generic notes app. Keep the meeting transcription story visible.

## Screenshot Data Checklist

- Use fabricated names, organizations, and meeting content.
- Include at least one transcript that reads like a professional meeting, not a quick reminder.
- Include model name/status where possible, because model control is part of the value proposition.
- Include iCloud only as optional user-account sync, not as the transcription engine.
- Hide personal Share Sheet contacts before capturing.
