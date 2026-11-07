import Testing
@testable import Voicely

struct AcknowledgementsTests {
    @Test func apacheLicenseTextShipsWithTheApp() {
        let text = Acknowledgement.apache2Text
        #expect(text.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
    }

    @Test func everyEntryCarriesItsLicenseText() {
        for item in Acknowledgement.all {
            switch item.license {
            case .apache2:
                #expect(item.licenseText.contains("Apache License"), "\(item.name)")
            case .mit(let copyright):
                #expect(item.licenseText.hasPrefix(copyright), "\(item.name)")
                #expect(item.licenseText.contains("Permission is hereby granted"), "\(item.name)")
            case .ccBy4:
                #expect(item.licenseText.contains("creativecommons.org/licenses/by/4.0"), "\(item.name)")
            }
        }
    }
}
