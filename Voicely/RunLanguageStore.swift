import Foundation

/// Where the language of one transcription run came from, as the log names it.
enum RunLanguageSource: String {
    /// The Speech Language setting when the run was requested.
    case setting
    /// Re-transcribing: the language the note was last transcribed in.
    case noteLanguage
    /// The user picked another language for this run.
    case userChoice
    /// "Switch to Auto Detect" during a recording with English chosen.
    case recordingSwitch
}

/// The language each unfinished transcription run uses, fixed when the run is
/// requested. Kept on this device only, so a run resumed after the app was
/// closed, or after the setting changed, keeps the language it started with.
struct RunLanguageStore {
    struct Entry: Equatable {
        /// One of `Qwen3ASRDefaults.languageKeys`.
        var key: String
        var source: RunLanguageSource
    }

    static let defaultsKey = "VoicelyRunLanguageByNote"

    /// Nil keeps the choices in memory only, as tests do.
    let defaults: UserDefaults?

    static let live = RunLanguageStore(defaults: AppRuntime.isRunningTests ? nil : .standard)

    func load() -> [UUID: Entry] {
        guard let stored = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: String] else { return [:] }
        var entries: [UUID: Entry] = [:]
        for (id, value) in stored {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            guard let noteID = UUID(uuidString: id), let key = parts.first else { continue }
            let source = parts.count > 1 ? RunLanguageSource(rawValue: parts[1]) ?? .setting : .setting
            entries[noteID] = Entry(key: Qwen3ASRDefaults.languageKey(key), source: source)
        }
        return entries
    }

    func save(_ entries: [UUID: Entry]) {
        guard let defaults else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(
            Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, "\($0.value.key)|\($0.value.source.rawValue)") }),
            forKey: Self.defaultsKey)
    }
}
