//
//  AcknowledgementsView.swift
//  Voicely
//
//  Credits and licenses for the models and libraries that ship in the app.
//

import SwiftUI

struct Acknowledgement: Identifiable {
    enum License {
        case apache2
        case mit(copyright: String)
        case ccBy4

        var name: String {
            switch self {
            case .apache2: return "Apache License 2.0"
            case .mit: return "MIT License"
            case .ccBy4: return "CC BY 4.0"
            }
        }
    }

    let name: String
    /// What the app uses it for and who made it, including any conversion
    /// of the original work.
    let credit: String
    let license: License
    let url: URL

    var id: String { name }

    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "Qwen3-ASR 0.6B",
            credit: "Speech recognition model by the Qwen team, Alibaba Cloud. The Mac uses the 8-bit MLX conversion by mlx-community; iPhone and iPad use the Core ML conversion by aufklarer.",
            license: .apache2,
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-ASR-0.6B")!
        ),
        Acknowledgement(
            name: "Parakeet TDT 0.6B v2",
            credit: "English speech recognition model by NVIDIA, used in the Core ML conversion by FluidInference (converted from the original; no other changes).",
            license: .ccBy4,
            url: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!
        ),
        Acknowledgement(
            name: "Silero VAD",
            credit: "Voice activity detection model by the Silero Team, used in a Core ML conversion.",
            license: .mit(copyright: "Copyright (c) 2020-present Silero Team"),
            url: URL(string: "https://github.com/snakers4/silero-vad")!
        ),
        Acknowledgement(
            name: "speech-swift",
            credit: "Qwen3-ASR and voice activity detection runtime by soniqo. Voicely includes a modified subset.",
            license: .apache2,
            url: URL(string: "https://github.com/soniqo/speech-swift")!
        ),
        Acknowledgement(
            name: "FluidAudio",
            credit: "Parakeet runtime by FluidInference.",
            license: .apache2,
            url: URL(string: "https://github.com/FluidInference/FluidAudio")!
        ),
        Acknowledgement(
            name: "OpenCC",
            credit: "Simplified and Traditional Chinese conversion dictionaries by the OpenCC project. Voicely uses them with its own Swift implementation of OpenCC's matching.",
            license: .apache2,
            url: URL(string: "https://github.com/BYVoid/OpenCC")!
        ),
        Acknowledgement(
            name: "MLX Swift",
            credit: "Machine learning on Apple silicon GPUs, by ml-explore.",
            license: .mit(copyright: "Copyright (c) 2023 ml-explore"),
            url: URL(string: "https://github.com/ml-explore/mlx-swift")!
        ),
        Acknowledgement(
            name: "swift-transformers",
            credit: "Tokenizers, by Hugging Face.",
            license: .apache2,
            url: URL(string: "https://github.com/huggingface/swift-transformers")!
        ),
        Acknowledgement(
            name: "Jinja",
            credit: "Template engine used by swift-transformers, by Hugging Face.",
            license: .apache2,
            url: URL(string: "https://github.com/huggingface/swift-jinja")!
        ),
        Acknowledgement(
            name: "Swift Collections",
            credit: "Data structures, by Apple.",
            license: .apache2,
            url: URL(string: "https://github.com/apple/swift-collections")!
        ),
        Acknowledgement(
            name: "Swift Numerics",
            credit: "Numeric types, by Apple.",
            license: .apache2,
            url: URL(string: "https://github.com/apple/swift-numerics")!
        ),
    ]

    static let mitPermissionNotice = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    static let ccBy4Notice = """
    This model is licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0). To view a copy of this license, visit https://creativecommons.org/licenses/by/4.0/
    """

    /// The Apache License 2.0 text, shipped as a resource.
    static var apache2Text: String {
        guard let url = Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0"
        }
        return text
    }

    var licenseText: String {
        switch license {
        case .apache2: return Self.apache2Text
        case .mit(let copyright): return "\(copyright)\n\n\(Self.mitPermissionNotice)"
        case .ccBy4: return Self.ccBy4Notice
        }
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Voicely is built on these models and open-source libraries. Thank you to their authors.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                ForEach(Acknowledgement.all) { item in
                    NavigationLink {
                        AcknowledgementDetailView(item: item)
                    } label: {
                        AcknowledgementRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(VoicelyTheme.groupedBackground.ignoresSafeArea())
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementRow: View {
    let item: Acknowledgement

    var body: some View {
        SurfaceCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    Text(item.credit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.license.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VoicelyTheme.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

private struct AcknowledgementDetailView: View {
    let item: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.credit)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Link(item.url.absoluteString, destination: item.url)
                    .font(.subheadline)
                Divider()
                Text(item.licenseText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VoicelyTheme.groupedBackground.ignoresSafeArea())
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
