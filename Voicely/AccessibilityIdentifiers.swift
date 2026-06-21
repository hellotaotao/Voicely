import Foundation

enum AccessibilityIdentifiers {
    enum Onboarding {
        static let screen = "FirstLaunchOnboardingScreen"
        static let pageTitle = "FirstLaunchOnboardingPageTitle"
        static let nextButton = "FirstLaunchOnboardingNextButton"
        static let finishButton = "FirstLaunchOnboardingFinishButton"
    }

    enum Navigation {
        static let libraryScreen = "LibraryScreen"
        static let settingsButton = "SettingsButton"
    }

    enum Library {
        static let noteList = "NoteLibraryList"
        static let noteRow = "VoiceNoteRow"
        static let emptyState = "EmptyLibraryCard"
        static let syncStatusBanner = "SyncStatusBanner"
        static let recordingControls = "RecordingControls"
        static let recordingModelPickerButton = "RecordingModelPickerButton"
        static let recordButton = "RecordButton"
        static let pauseRecordingButton = "PauseRecordingButton"
        static let stopRecordingButton = "StopRecordingButton"
        static let detailPlaceholder = "DetailPlaceholder"
    }

    enum Detail {
        static let screen = "NoteDetailScreen"
        static let title = "NoteDetailTitle"
        static let metadata = "NoteDetailMetadata"
        static let editButton = "NoteDetailEditButton"
        static let audioPlayerCard = "AudioPlayerCard"
        static let playButton = "PlayButton"
        static let playbackRateButton = "PlaybackRateButton"
        static let transcriptionCard = "TranscriptionCard"
        static let computeTelemetryCard = "ComputeTelemetryCard"
        static let transcriptionBody = "TranscriptionBody"
        static let transcriptEditor = "TranscriptEditor"
        static let copyTranscriptionButton = "CopyTranscriptionButton"
        static let shareTranscriptionButton = "ShareTranscriptionButton"
        static let transcribeButton = "TranscribeButton"
        static let retranscribeButton = "RetranscribeButton"
        static let takeOverTranscriptionButton = "TakeOverTranscriptionButton"
        static let transcribeNowButton = "TranscribeNowButton"
        static let cancelTranscriptionButton = "CancelTranscriptionButton"
    }

    enum Settings {
        static let screen = "SettingsScreen"
        static let doneButton = "SettingsDoneButton"
        static let activeModelCard = "ActiveModelCard"
        static let modelPicker = "ModelPicker"
        static let languageSection = "LanguageSettingsSection"
        static let transcriptionSection = "TranscriptionSettingsSection"
        static let computeSection = "ComputeSettingsSection"
        static let aboutSection = "AboutSettingsSection"
        static let speechLanguagePicker = "SpeechLanguagePicker"
        static let customPromptField = "CustomPromptField"
        static let browseModelsLink = "BrowseModelsLink"
        static let runBenchmarkLink = "RunBenchmarkLink"
    }
}
