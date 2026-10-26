# Screenshot Plan

Story: record a meeting, get the whole transcript on the device, use it. Use invented meeting names and transcript text; never a real meeting.

## Sizes

Check App Store Connect's current requirements before capturing.

- iPhone 6.9-inch: 1320 × 2868 portrait (iPhone 17 Pro Max / 16 Pro Max class). Required; smaller iPhone sizes are scaled from it.
- iPad 13-inch: 2064 × 2752 portrait. Required because the app runs on iPad.
- Mac: 16:10, e.g. 2880 × 1800 or 1440 × 900.

## iPhone Set (6 screenshots)

| # | Screen and state | Caption |
| --- | --- | --- |
| 1 | Recording in progress: timer past 30 minutes, waveform, live transcript filling in below | Transcribes while you record |
| 2 | Finished note: full transcript, playback bar, a highlighted sentence | Tap any sentence to hear it |
| 3 | Lock Screen with the recording Live Activity | Keeps going when your iPhone is locked |
| 4 | Mixed Chinese and English transcript | Handles meetings in two languages |
| 5 | Stop timer: "Stops at 15:30" with the +10 min option | Stops on time, or keeps going |
| 6 | Settings: the speech model card and "Fully on-device" card | Speech recognition stays on your device |

Alternative for 6: the transcript's Copy and Share actions, captioned "Copy it into your AI assistant".

## iPad Set

The split view: note list on the left, transcript and playback on the right. Reuse captions 1, 2, 4 and 6.

## Mac Set

The same split view in a Mac window, one shot recording and one finished transcript. Captions 1 and 2, plus "Fast transcription on Apple silicon".

## Capture Notes

- Mac first: capture the Mac set from the running app; the iPhone and iPad sets need the simulator or a device, which belongs to the pre-release iPhone pass.
- Clean status bar on the simulator: `xcrun simctl status_bar booted override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`; reset with `xcrun simctl status_bar booted clear`.
- Sample note titles: "Q3 Vendor Review", "Product Sync", "Hiring Debrief", "季度规划会".
- Avoid claims the app cannot back: "compliant", "certified", "zero cloud", "never syncs". iCloud sync exists and is optional.
- Hide personal contacts in any Share Sheet before capturing.
- Captions sit outside the app UI, high contrast, clear of navigation bars and buttons.
