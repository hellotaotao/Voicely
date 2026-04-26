# App Store Release Checklist

This checklist prepares the package only. Do not submit to Apple until the product owner explicitly approves the final listing and build.

## Local Preflight

- Confirm final release version and build number. Current app target is `MARKETING_VERSION = 0.15.3` and `CURRENT_PROJECT_VERSION = 1` in `Voicely.xcodeproj/project.pbxproj`.
- Decide whether the first official App Store version should be `1.0`, `1.0.0`, or remain `0.15.3`.
- Confirm bundle ID is `com.hellotaotao.Voicely`.
- Confirm deployment target and device families: iPhone and iPad are enabled in the app target.
- Confirm the release archive uses App Store distribution signing.
- Confirm production archive entitlements for iCloud/CloudKit and APNs. The checked-in entitlements file contains development APNs values, so verify the archived entitlements from Xcode Organizer before upload.
- Confirm `ITSAppUsesNonExemptEncryption=false` remains accurate.
- Confirm CloudKit container `iCloud.com.hellotaotao.Voicely` and production schema are ready if shipping iCloud sync.
- Confirm microphone and speech/transcription permission strings are acceptable for the final build.
- Confirm a clean install can download/load a WhisperKit model and transcribe a short recording.

## Xcode / Build Upload

- Open `Voicely.xcodeproj` in Xcode.
- Select the `Voicely` scheme and a generic iOS device destination.
- Set final version/build values if needed.
- Product > Archive.
- In Organizer, select the archive and validate it.
- If no suitable TestFlight build exists, Distribute App > App Store Connect > Upload.
- Wait for App Store Connect processing.
- Do not push or submit from this release-prep task.

## App Store Connect Setup

- Create or open the app record for Voicely.
- Add a new app version matching the uploaded build version.
- Select the processed build from TestFlight/build list.
- Fill metadata from `docs/app-store-release/app-store-metadata.md`.
- Upload screenshots using `docs/app-store-release/screenshot-plan.md`.
- Set category to Productivity, with Business as secondary if desired.
- Complete age rating questionnaire using the notes in `app-store-metadata.md`.
- Complete App Privacy answers using `privacy-and-review-notes.md`.
- Complete export compliance. Based on current `Info.plist`, answer that the app does not use non-exempt encryption, assuming no new encryption code was added.
- Set pricing and availability.
- Add review contact information.
- Paste App Review notes from `privacy-and-review-notes.md`, adjusted for the final build.
- Save all changes.
- Stop before clicking Submit for Review unless explicitly approved.

## Manual Items The Owner Must Complete

- Publish and enter a live Support URL.
- Publish and enter a live Marketing URL if using one.
- Confirm copyright/legal entity.
- Confirm privacy policy/support page wording.
- Confirm App Privacy Nutrition Label with legal/privacy owner.
- Confirm CloudKit production readiness and any required container/schema deployment.
- Confirm pricing, availability, age rating, content rights, and export compliance.
- Confirm final screenshots and captions.
- Confirm the final selected build is the intended TestFlight-tested build.
- Click Submit for Review only after final approval.

## Post-Package Verification

- Run `git diff --check`.
- Review the created docs under `docs/app-store-release/`.
- Commit locally with `docs: prepare App Store release package`.
- Do not push.
