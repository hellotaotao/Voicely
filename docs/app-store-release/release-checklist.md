# App Store Release Checklist

For Voicely's first public release (iPhone, iPad, and Mac in one listing). This package prepares the submission; clicking Submit for Review is the owner's call.

## Before Archiving

- Pass the iPhone acceptance in `docs/stable-roadmap.md` (item 6): a minimum-supported and a recent device, foreground and locked, a 60–90 minute meeting end to end, iOS 18 and iOS 26 background paths, scheduled stop on the Lock Screen, recovery after the app is killed mid-recording. The listing's background claims depend on it.
- Decide the public version (`1.0` or `0.28.x`) and set it in `Config/Version.xcconfig`, the only place versions are set.
- Deploy the CloudKit schema from development to production in CloudKit Console (container `iCloud.com.hellotaotao.Voicely`). Release and TestFlight builds use production; an outdated production schema makes sync fail.
- Confirm `ITSAppUsesNonExemptEncryption = false` still holds.
- Confirm a clean install transcribes a short recording with no network (airplane mode, iCloud off).

## Build And Upload

Follow the release procedure (bundled model, arm64-only Mac archive):

1. Run `scripts/fetch-speech-models.sh` if `Models/` is missing.
2. Commit and push the version bump, then tag `vX.Y.Z`.
3. Archive both platforms:
   - iOS: `xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=iOS' archive`
   - Mac: `xcodebuild -scheme Voicely -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' ARCHS=arm64 archive`
4. Upload each with `xcodebuild -exportArchive` (App Store Connect, upload) or from Organizer. Each package is about 1.1 GB and takes roughly 15 minutes to upload.
5. In Organizer, check that the archived entitlements use the production push environment.
6. Wait for processing, then smoke-test both builds from TestFlight.

## App Store Connect

- Create the app version for iOS and for macOS, using the same version number.
- Select the processed builds.
- Metadata from `app-store-metadata.md`; add the Chinese (Simplified) localization.
- Screenshots from `screenshot-plan.md`.
- Category: Productivity, secondary Business.
- Age rating questionnaire (likely 4+).
- App Privacy from `privacy-and-review-notes.md` (recommended: Data Not Collected); privacy policy URL must match.
- Export compliance: no non-exempt encryption.
- Mac availability: Apple silicon only.
- Pricing and availability.
- Review contact details and the App Review notes from `privacy-and-review-notes.md`.
- Save; submit only after the owner approves the listing and builds.

## Owner Items

- Publish the support page and privacy policy; enter their URLs (and a marketing URL if used).
- Confirm the copyright holder.
- Choose the App Privacy answer and keep the privacy policy consistent with it.
- Approve final screenshots and copy.
- Click Submit for Review.
