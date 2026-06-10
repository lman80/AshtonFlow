import Foundation
import WhisperKit

/// UI-facing state of the local Whisper model (shown in Settings).
enum LocalModelState: Equatable {
    case notLoaded
    case downloading(Double)   // 0...1 download fraction
    case loading               // downloaded; loading into memory
    case ready
    case failed(String)
}

/// State of switching to a *different* offline model: it downloads in the
/// background while the current model keeps transcribing, then activates.
enum ModelSwitchState: Equatable {
    case idle
    case downloading(model: String, fraction: Double)
    case activating(model: String)
    case failed(model: String, message: String)
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

    /// Whether the given model already exists on disk (downloaded previously), so
    /// we can warm it at launch without triggering a fresh network download.
    nonisolated static func hasDownloadedModel(named modelName: String) -> Bool {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return false
        }
        let needle = modelName.lowercased()
        return entries.contains { $0.lowercased().contains(needle) }
    }

    /// Download a model's files to disk (incremental — skips files already
    /// present) WITHOUT touching the active model, so a newly-picked model can
    /// download in the background while the current one keeps transcribing.
    nonisolated static func ensureDownloaded(
        _ name: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(variant: name, progressCallback: { progress in
            onProgress(progress.fractionCompleted)
        })
    }

    private var loadingTask: Task<WhisperKit, Error>?

    /// Switch the model; drops the loaded instance so the next prepare() reloads.
    func setModel(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != modelName else { return }
        modelName = trimmed
        whisperKit = nil
        loadingTask = nil
    }

    /// Downloads (with progress) on first use, then loads the model into memory.
    /// Safe to call repeatedly and concurrently — a single in-flight load is
    /// shared so we never download the same model twice at once.
    @discardableResult
    func prepare(
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onLoading: (@Sendable () -> Void)? = nil
    ) async throws -> WhisperKit {
        if let whisperKit {
            onLoading?()
            return whisperKit
        }
        if let loadingTask {
            return try await loadingTask.value
        }
        let name = modelName
        let task = Task { () throws -> WhisperKit in
            // Download (incremental — skips files already present) with progress.
            let folder = try await WhisperKit.download(variant: name, progressCallback: { progress in
                onProgress?(progress.fractionCompleted)
            })
            // Load the downloaded model into memory.
            onLoading?()
            return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path))
        }
        loadingTask = task
        do {
            let kit = try await task.value
            whisperKit = kit
            loadingTask = nil
            return kit
        } catch {
            loadingTask = nil
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
