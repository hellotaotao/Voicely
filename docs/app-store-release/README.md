# App Store Release Package

This folder is the single home for everything related to publishing Voicely on the App Store. It does not submit anything to Apple — it is local prep material only.

## Status (updated 2026-08-29)

- **Next build is TestFlight, not the App Store.** `Config/Version.xcconfig` is now
  `MARKETING_VERSION = 0.24.0`, build `1` — the first build since 0.23.1 was archived on
  2026-07-05. It closes out the two months of fixes that had piled up unreleased; see the
  0.24.0 release note in `AGENTS.md` for what changed and why Qwen3 is not the default.
- **1.0.0 is still reserved for the first public App Store release** and is not applied.
  Set it only when actually archiving for submission. Earlier `0.18.5` was **TestFlight-only**
  — the app has never been publicly released on the App Store (confirmed: 0 hits across 9
  regions by bundle id `com.hellotaotao.Voicely`).
- **Which build actually reached TestFlight is unconfirmed locally.** The last Xcode archive
  is 0.23.1 (1), 2026-07-05 (tag `archive-20260705-213228`, commit `485f944`), but no Apple
  "ready to test" mail for Voicely exists after 0.9.0 (4) in June 2025 — while EverLog,
  JustaTuner and GridGuide mails from 2026 did arrive. Archiving is not distributing, so
  check App Store Connect before assuming a build is out there.
- An **old auto-stash from 2026-03-16** (`git stash@{0}`, "Auto stash before checking out HEAD") holds earlier, now-superseded drafts (`docs/AppStoreReleasePrep.md`, `docs/PrivacyPolicyDraft.md`, `docs/SupportPageDraft.md`, `scripts/release_testflight.sh`). Left untouched. Recover with `git stash apply stash@{0}` if any of it is still wanted.

## Files

- `app-store-metadata.md`: App Store Connect copy (name, subtitle, keywords, description), "What's New" for 1.0.0, category suggestion, URLs to finalize, and age rating notes. English + Chinese.
- `submission-checklist.md`: End-to-end first-time submission checklist (region availability, version/build, CloudKit prod, privacy, review notes, upload).
- `release-checklist.md`: Earlier Xcode / App Store Connect checklist for selecting a TestFlight build and preparing the listing.
- `privacy-and-review-notes.md`: App Review notes, App Privacy Nutrition Label draft, permission rationale, and export compliance notes.
- `screenshot-plan.md`: iPhone screenshot narrative with exact overlay captions.
- `widget-shortcuts-roadmap.md`: Planning notes for future Voicely widgets, App Shortcuts, AppIntents, and privacy-safe system entry points.
- `screenshots/`: Captured screenshots. Currently holds **preliminary** 6.9" captures (1320×2868) of the empty main screen and onboarding — placeholders only. The compelling shots (tap-to-seek transcript, live streaming) still need real recording + a loaded model, per `screenshot-plan.md`.

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
