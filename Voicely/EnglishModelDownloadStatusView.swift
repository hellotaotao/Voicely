import SwiftUI

/// How the English & European model's download reads on screen. It names
/// the languages, never the model, and never suggests the other model is
/// anywhere but on the device.
enum EnglishModelDownloadCopy {
    /// The status line under the speech model's status.
    static func line(for display: EnglishModelDownloadDisplay) -> String? {
        switch display {
        case .hidden:
            return nil
        case .downloading(let percent):
            return String(localized: "English & European model · downloading \(percent)%")
        case .waitingForWiFi(let bytes):
            let size = EnglishModelDownloadPolicy.sizeText(bytes: bytes)
            return String(localized: "English & European model · downloads on Wi‑Fi (\(size))")
        }
    }

    /// Beside the English & European choice in the language menus.
    static func choiceSuffix(for display: EnglishModelDownloadDisplay) -> String? {
        switch display {
        case .hidden:
            return nil
        case .downloading(let percent):
            return String(localized: "downloading \(percent)%")
        case .waitingForWiFi:
            return String(localized: "downloads on Wi‑Fi")
        }
    }

    static var footnote: String {
        String(localized: "You can record and transcribe now. Once it's in, English & European languages get much faster and more accurate.")
    }
}

/// The English & European model's download: a status line, Download now
/// while it waits for Wi‑Fi, and what it changes. Shows nothing once the
/// model is in, or on a device that cannot download it.
struct EnglishModelDownloadStatusView: View {
    @ObservedObject var download = EnglishModelDownload.shared
    var font: Font = .footnote
    var footnoteFont: Font = .caption
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let display = download.display
        if let line = EnglishModelDownloadCopy.line(for: display) {
            VStack(alignment: alignment, spacing: 6) {
                HStack(spacing: 8) {
                    if case .downloading = display {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(line)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if case .waitingForWiFi = display {
                        Button(String(localized: "Download now")) {
                            download.downloadNow()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("englishModel.downloadNow")
                    }
                }
                .font(font)
                Text(EnglishModelDownloadCopy.footnote)
                    .font(footnoteFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("englishModel.downloadStatus")
        }
    }
}
