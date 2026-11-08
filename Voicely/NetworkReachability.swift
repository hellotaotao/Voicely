import Foundation
import Network

/// Whether the device has a network path, for audio that is still in iCloud:
/// without one it cannot download, so transcription waits instead of timing
/// out. A path is no promise iCloud answers; it only rules out the plain
/// offline case.
@MainActor
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    /// Nil until the first path update arrives.
    @Published private(set) var isOnline: Bool?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkReachability.shared.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.hellotaotao.Voicely.network"))
    }

    /// Known to be offline; unknown counts as online.
    var isKnownOffline: Bool { isOnline == false }

    private func update(online: Bool) {
        let wasOffline = isOnline == false
        guard isOnline != online else { return }
        isOnline = online
        if online && wasOffline {
            NotificationCenter.default.post(name: .networkBecameAvailable, object: nil)
        }
    }
}

extension Notification.Name {
    static let networkBecameAvailable = Notification.Name("VoicelyNetworkBecameAvailable")
}
