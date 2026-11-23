import Foundation
import Testing
@testable import Voicely

struct EnglishModelDownloadTests {
    // MARK: Rules

    @Test(arguments: [
        (true, false, false, true),   // Wi‑Fi
        (true, true, false, false),   // cellular or a personal hotspot
        (true, false, true, false),   // Low Data Mode
        (true, true, true, false),
        (false, false, false, false), // offline
    ])
    func automaticDownloadsTakeWiFiOutsideLowDataModeOnly(online: Bool, expensive: Bool, constrained: Bool, allowed: Bool) {
        #expect(EnglishModelDownloadPolicy.allowsAutomaticDownload(
            isOnline: online, isExpensive: expensive, isConstrained: constrained) == allowed)
    }

    @Test func nothingShowsOnceTheModelIsInOrWhereItCannotBeDownloaded() {
        #expect(EnglishModelDownloadPolicy.display(isSupported: true, isReady: true, progress: 0.4, downloadSize: nil) == .hidden)
        #expect(EnglishModelDownloadPolicy.display(isSupported: false, isReady: false, progress: nil, downloadSize: nil) == .hidden)
    }

    @Test func aRunningDownloadShowsWholePercentsAndNever100() {
        #expect(EnglishModelDownloadPolicy.display(isSupported: true, isReady: false, progress: 0.409, downloadSize: nil)
                == .downloading(percent: 40))
        #expect(EnglishModelDownloadPolicy.display(isSupported: true, isReady: false, progress: 1, downloadSize: nil)
                == .downloading(percent: 99))
        #expect(EnglishModelDownloadPolicy.display(isSupported: true, isReady: false, progress: -1, downloadSize: nil)
                == .downloading(percent: 0))
    }

    @Test func withoutADownloadItWaitsForWiFiWithTheSystemsSizeOrOurs() {
        #expect(EnglishModelDownloadPolicy.display(isSupported: true, isReady: false, progress: nil, downloadSize: 700_000_000)
                == .waitingForWiFi(bytes: 700_000_000))
        #expect(EnglishModelDownloadPolicy.display(isSupported: true, isReady: false, progress: nil, downloadSize: nil)
                == .waitingForWiFi(bytes: EnglishModelAssetPack.fallbackDownloadSize))
    }

    @Test func theSizeReadsInTensOfMegabytes() {
        #expect(EnglishModelDownloadPolicy.sizeText(bytes: 632_200_000) == "630 MB")
        #expect(EnglishModelDownloadPolicy.sizeText(bytes: 636_000_000) == "640 MB")
    }

    @Test func theLinesNameTheLanguagesAndTheSize() {
        #expect(EnglishModelDownloadCopy.line(for: .downloading(percent: 40)) == "English & European model · downloading 40%")
        #expect(EnglishModelDownloadCopy.line(for: .waitingForWiFi(bytes: 632_000_000))
                == "English & European model · downloads on Wi‑Fi (630 MB)")
        #expect(EnglishModelDownloadCopy.line(for: .hidden) == nil)
        #expect(SpeechLanguageCopy.name(for: "english", englishModel: .downloading(percent: 40))
                == "English & European (faster) · downloading 40%")
        #expect(SpeechLanguageCopy.name(for: "english", englishModel: .hidden) == "English & European (faster)")
        #expect(SpeechLanguageCopy.name(for: "auto", englishModel: .waitingForWiFi(bytes: 1)) == "All supported languages")
    }

    // MARK: Requests

    @MainActor
    private final class Fake {
        var available = false
        var requests = 0
        var userRequested: [Bool] = []
        var failNext = false

        func make() -> EnglishModelDownload {
            EnglishModelDownload(
                isSupported: true,
                isModelAvailable: { [unowned self] in self.available },
                ensureAvailability: { [unowned self] in
                    self.requests += 1
                    if self.failNext {
                        self.failNext = false
                        throw CocoaError(.fileReadUnknown)
                    }
                    self.available = true
                },
                setUserRequested: { [unowned self] in self.userRequested.append($0) })
        }
    }

    @Test @MainActor func wiFiStartsTheDownloadAndCellularDoesNot() async {
        let fake = Fake()
        let download = fake.make()
        #expect(download.display == .waitingForWiFi(bytes: EnglishModelAssetPack.fallbackDownloadSize))

        download.networkChanged(isOnline: true, isExpensive: true, isConstrained: false)
        await download.waitForRequest()
        #expect(fake.requests == 0)

        download.networkChanged(isOnline: true, isExpensive: false, isConstrained: true)
        await download.waitForRequest()
        #expect(fake.requests == 0)

        download.networkChanged(isOnline: true, isExpensive: false, isConstrained: false)
        #expect(download.display == .downloading(percent: 0))
        await download.waitForRequest()
        #expect(fake.requests == 1)
        #expect(download.isReady)
        #expect(download.display == .hidden)
        #expect(fake.userRequested == [false])
    }

    @Test @MainActor func downloadNowTakesCellularAndTellsTheExtension() async {
        let fake = Fake()
        let download = fake.make()
        download.networkChanged(isOnline: true, isExpensive: true, isConstrained: false)

        download.downloadNow()
        await download.waitForRequest()

        #expect(fake.requests == 1)
        #expect(fake.userRequested == [true, false])
        #expect(download.isReady)
    }

    @Test @MainActor func aFailedAutomaticRequestWaitsForTheNetworkToChange() async {
        let fake = Fake()
        fake.failNext = true
        let download = fake.make()

        download.networkChanged(isOnline: true, isExpensive: false, isConstrained: false)
        await download.waitForRequest()
        #expect(fake.requests == 1)
        #expect(!download.isReady)
        #expect(download.display == .waitingForWiFi(bytes: EnglishModelAssetPack.fallbackDownloadSize))

        // The same network again does not retry.
        download.networkChanged(isOnline: true, isExpensive: false, isConstrained: false)
        await download.waitForRequest()
        #expect(fake.requests == 1)

        download.networkChanged(isOnline: false, isExpensive: false, isConstrained: false)
        download.networkChanged(isOnline: true, isExpensive: false, isConstrained: false)
        await download.waitForRequest()
        #expect(fake.requests == 2)
        #expect(download.isReady)
    }

    @Test @MainActor func theSystemsOwnDownloadShowsItsProgress() {
        let fake = Fake()
        let download = fake.make()

        download.apply(.progress(0.42))
        #expect(download.display == .downloading(percent: 42))
        download.apply(.paused)
        #expect(download.display == .waitingForWiFi(bytes: EnglishModelAssetPack.fallbackDownloadSize))
        download.apply(.progress(0.5))
        download.apply(.failed)
        #expect(download.display == .waitingForWiFi(bytes: EnglishModelAssetPack.fallbackDownloadSize))

        download.apply(.progress(0.9))
        fake.available = true
        download.apply(.finished)
        #expect(download.isReady)
        #expect(download.display == .hidden)
        // A late report changes nothing.
        download.apply(.progress(0.95))
        #expect(download.display == .hidden)
    }

    @Test @MainActor func aModelAlreadyInShowsNothingAndAsksForNothing() async {
        let fake = Fake()
        fake.available = true
        let download = fake.make()

        download.networkChanged(isOnline: true, isExpensive: false, isConstrained: false)
        download.downloadNow()
        await download.waitForRequest()

        #expect(download.isReady)
        #expect(fake.requests == 0)
        #expect(download.display == .hidden)
    }

    // MARK: Routing

    @Test @MainActor func englishAndEuropeanGoesToQwenUntilTheModelIsIn() {
        let service = TranscriptionService()
        let note = UUID()
        service.setLanguageKey("english", for: note)

        service.englishModelIsReady = { false }
        #expect(service.languageHint(for: note) == nil)
        #expect(!service.transcribesWithParakeet(note))

        service.englishModelIsReady = { true }
        #expect(service.languageHint(for: note) == "English")
        #expect(service.transcribesWithParakeet(note))
    }

    @Test func noStretchGoesToParakeetBeforeItIsIn() async {
        let slices = EnglishStretchRoutingTests.slices(Array(repeating: "English", count: 4))
        #expect(await EnglishStretchRouting.stretchesInBackground(in: slices, mode: .automatic, englishModelIsReady: false).isEmpty)
        #expect(await EnglishStretchRouting.stretchesInBackground(in: slices, mode: .automatic, englishModelIsReady: true) == [0...3])
    }
}
