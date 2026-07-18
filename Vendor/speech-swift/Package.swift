// swift-tools-version: 5.10
import PackageDescription

// Vendored subset of https://github.com/soniqo/speech-swift
// at revision 1ad4606418cc98df11197f898a34907e2dd1c4a2 (Apache-2.0, see LICENSE).
// Copied from EverLog-iOS's vendored tree, which carries a one-line Mac
// Catalyst fix (missing `import CoreAudio` in AudioCommon/
// StreamingAudioPlayer.swift) — see PATCHES.md. Only the four targets the
// Qwen3ASR engine needs are kept (Qwen3ASR + its dependencies); TTS/server/
// CLI/benchmark targets and the CSpeechCore binary artifact are dropped.
//
// Once upstream builds for Catalyst, delete this directory and reference the
// remote package instead.
let package = Package(
    name: "Qwen3Speech",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0")
    ],
    products: [
        .library(name: "Qwen3ASR", targets: ["Qwen3ASR"]),
        .library(name: "SpeechVAD", targets: ["SpeechVAD"]),
        .library(name: "AudioCommon", targets: ["AudioCommon"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6")
    ],
    targets: [
        .target(
            name: "AudioCommon",
            dependencies: [
                .product(name: "Hub", package: "swift-transformers")
            ]
        ),
        .target(
            name: "MLXCommon",
            dependencies: [
                "AudioCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift")
            ]
        ),
        .target(
            name: "SpeechVAD",
            dependencies: [
                "AudioCommon",
                "MLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift")
            ]
        ),
        .target(
            name: "Qwen3ASR",
            dependencies: [
                "AudioCommon",
                "MLXCommon",
                "SpeechVAD",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift")
            ]
        )
    ]
)
