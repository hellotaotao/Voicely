# App Store Release Package

This folder contains the local release-prep package for Voicely's first official App Store listing. It does not submit anything to Apple.

## Files

- `app-store-metadata.md`: App Store Connect copy, category suggestion, keywords, URLs to finalize, and age rating notes.
- `privacy-and-review-notes.md`: App Review notes, App Privacy Nutrition Label draft, permission rationale, and export compliance notes.
- `screenshot-plan.md`: 6.7-inch iPhone screenshot narrative with exact overlay captions.
- `release-checklist.md`: Xcode and App Store Connect checklist for selecting a TestFlight build and preparing the listing.
- `widget-shortcuts-roadmap.md`: Planning notes for future Voicely widgets, App Shortcuts, AppIntents, and privacy-safe system entry points.

## Simulator Screenshot Guidance

Use these as local-only helper commands after launching the app in a simulator. They do not perform network or App Store actions.

1. Boot a 6.7-inch iPhone simulator from Xcode, for example an iPhone Pro Max device.
2. Run Voicely from Xcode or install the intended archived/TestFlight-equivalent build.
3. Set a clean status bar:

```sh
xcrun simctl status_bar booted override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
```

4. Capture each screenshot:

```sh
mkdir -p docs/app-store-release/screenshots
xcrun simctl io booted screenshot docs/app-store-release/screenshots/01-library.png
```

5. Reset the status bar when finished:

```sh
xcrun simctl status_bar booted clear
```

Confirm current App Store Connect screenshot-size requirements before upload, and re-capture on the exact required simulator if Apple requests a different size class.
