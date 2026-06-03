import Foundation
import WhisperKit

/// UI-facing state of the local Whisper model (shown in Settings).
enum LocalModelState: Equatable {
    case notLoaded
    case preparing
    case ready
    case failed(String)
}

enum LocalTranscriptionError: LocalizedError {
    case modelNotReady(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady(let msg):
            return "Offline model not ready: \(msg). The model downloads once while you're online — connect to the internet and try again."
        case .transcriptionFailed(let msg):
            return "Local transcription failed: \(msg)"
        }
    }
}

/// On-device transcription using WhisperKit. Mirrors the interface of the cloud
/// `TranscriptionService` (`transcribe(fileURL:) async throws -> String`) so the
/// app can route to it when Offline mode is on. The Whisper model is downloaded
/// from Hugging Face once (needs internet), then runs fully offline.
actor LocalTranscriptionService {
    private var whisperKit: WhisperKit?
    private(set) var modelName: String

    init(modelName: String) {
        self.modelName = modelName
    }

    var isLoaded: Bool { whisperKit != nil }

    /// Switch the model; drops the loaded instance so the next prepare() reloads.
    func setModel(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != modelName else { return }
        modelName = trimmed
        whisperKit = nil
    }

    /// Loads the model into memory, downloading it on first use. Safe to call
    /// repeatedly; subsequent calls return the cached instance.
    @discardableResult
    func prepare() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        do {
            let config = WhisperKitConfig(model: modelName, download: true)
            let kit = try await WhisperKit(config)
            // If a concurrent call finished first, keep that one.
            if let existing = whisperKit { return existing }
            whisperKit = kit
            return kit
        } catch {
            throw LocalTranscriptionError.modelNotReady(error.localizedDescription)
        }
    }

    /// Transcribe an audio file fully on-device and return the plain text.
    func transcribe(fileURL: URL) async throws -> String {
        let kit = try await prepare()
        do {
            let results = try await kit.transcribe(audioPath: fileURL.path)
            let text = results
                .map { $0.text }
                .joined(separator: " ")
            return text
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw LocalTranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }
}
