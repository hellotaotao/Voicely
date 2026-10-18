// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "QwenReplay",
    platforms: [.macOS("15.0")],
    dependencies: [.package(path: "../../Vendor/speech-swift")],
    targets: [
        .executableTarget(name: "QwenReplay", dependencies: [.product(name: "Qwen3ASR", package: "speech-swift")])
        ,.executableTarget(name: "QwenCoreML", dependencies: [.product(name: "Qwen3ASR", package: "speech-swift"), .product(name: "AudioCommon", package: "speech-swift")])
    ]
)
