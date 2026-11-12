//
//  ModelContainerLoader.swift
//  Voicely
//

import Foundation
import os
import SwiftData
import UIKit

/// Owns the app's SwiftData container. iOS keeps the store encrypted from a
/// restart until the first unlock, and the system can launch the app in that
/// window (it restores a Live Activity, runs a background task). Opening the
/// store then fails, so the container waits for the unlock instead of crashing.
@MainActor
final class ModelContainerLoader: ObservableObject {
    @Published private(set) var container: ModelContainer?

    nonisolated private static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "Launch")

    private let make: () throws -> ModelContainer
    private let isProtectedDataAvailable: () -> Bool
    private let onUnrecoverableError: (Error) -> Void
    private let notificationCenter: NotificationCenter
    private var unlockObserver: NSObjectProtocol?

    init(
        make: @escaping () throws -> ModelContainer,
        isProtectedDataAvailable: @escaping () -> Bool,
        notificationCenter: NotificationCenter = .default,
        onUnrecoverableError: @escaping (Error) -> Void = { fatalError("Could not create ModelContainer: \($0)") }
    ) {
        self.make = make
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.notificationCenter = notificationCenter
        self.onUnrecoverableError = onUnrecoverableError
        load()
    }

    deinit {
        if let unlockObserver { notificationCenter.removeObserver(unlockObserver) }
    }

    private func load() {
        guard container == nil else { return }
        do {
            container = try make()
            if let unlockObserver {
                notificationCenter.removeObserver(unlockObserver)
                self.unlockObserver = nil
            }
        } catch {
            guard !isProtectedDataAvailable() else {
                onUnrecoverableError(error)
                return
            }
            Self.log.notice("event=storeWaitingForUnlock")
            waitForUnlock()
        }
    }

    private func waitForUnlock() {
        guard unlockObserver == nil else { return }
        unlockObserver = notificationCenter.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        // The unlock may have landed between the failed open and the observer.
        if isProtectedDataAvailable() { load() }
    }
}
