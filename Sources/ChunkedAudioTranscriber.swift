import Foundation
import AVFoundation

/// Transcribes a (possibly long) audio/video file via the cloud by splitting it
/// into short segments, exporting each to a small m4a, transcribing them in
/// parallel, and stitching the text back together in order.
///
/// This is what makes long files (e.g. a 1-hour meeting) work on the cloud:
/// uploading the whole file in one request blows past the provider's size limit
/// and times out. Chunks stay small, run concurrently (much faster), and give
/// real progress as each one finishes — no on-device fallback, so the machine
/// never has to grind through it locally.
enum ChunkedAudioTranscriber {

    /// Reports (fraction 0...1, completedChunks, totalChunks) as chunks finish.
    typealias ProgressHandler = @Sendable (Double, Int, Int) -> Void

    static func transcribe(
        fileURL: URL,
        apiKey: String,
        baseURL: String,
        model: String,
        language: String?,
        timeout: TimeInterval = 300,
        chunkSeconds: Double = 300,
        maxConcurrent: Int = 4,
        onProgress: @escaping ProgressHandler
    ) async throws -> String {
        let asset = AVURLAsset(url: fileURL)
        let totalSeconds = CMTimeGetSeconds(try await asset.load(.duration))

        // Unknown/short duration → just upload the file as one piece.
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            onProgress(0, 0, 1)
            let service = try makeService(apiKey: apiKey, baseURL: baseURL, model: model, language: language, timeout: timeout)
            let text = try await service.transcribe(fileURL: fileURL)
            onProgress(1, 1, 1)
            return text
        }

        let chunkCount = max(1, Int(ceil(totalSeconds / chunkSeconds)))
        let ranges: [(index: Int, start: Double, length: Double)] = (0..<chunkCount).map { i in
            let start = Double(i) * chunkSeconds
            return (i, start, min(chunkSeconds, totalSeconds - start))
        }

        onProgress(0, 0, chunkCount)
        var results = [String?](repeating: nil, count: chunkCount)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func addNext() {
                guard next < ranges.count else { return }
                let range = ranges[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let chunkURL = try await exportChunk(sourceURL: fileURL, start: range.start, length: range.length, index: range.index)
                    defer { try? FileManager.default.removeItem(at: chunkURL) }
                    let service = try makeService(apiKey: apiKey, baseURL: baseURL, model: model, language: language, timeout: timeout)
                    let text = try await transcribeWithRetry(service: service, fileURL: chunkURL)
                    return (range.index, text)
                }
            }

            for _ in 0..<min(maxConcurrent, ranges.count) { addNext() }

            while let (index, text) = try await group.next() {
                results[index] = text
                completed += 1
                onProgress(Double(completed) / Double(chunkCount), completed, chunkCount)
                addNext()
            }
        }

        return results
            .compactMap { $0 }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func makeService(apiKey: String, baseURL: String, model: String, language: String?, timeout: TimeInterval) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: apiKey,
            baseURL: baseURL,
            transcriptionModel: model,
            language: language,
            timeoutOverride: timeout
        )
    }

    private static func transcribeWithRetry(service: TranscriptionService, fileURL: URL, attempts: Int = 3) async throws -> String {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await service.transcribe(fileURL: fileURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    // Brief backoff (handles transient network / rate limits).
                    try? await Task.sleep(nanoseconds: UInt64((Double(attempt) + 1) * 1_000_000_000))
                }
            }
        }
        throw lastError ?? TranscriptionError.transcriptionFailed("Chunk transcription failed.")
    }

    /// Export just `[start, start+length)` of the source to a compact m4a.
    /// A fresh AVURLAsset per chunk keeps concurrent exports independent.
    private static func exportChunk(sourceURL: URL, start: Double, length: Double, index: Int) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioPreparationFailed("Couldn't read audio from this file.")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtonflow-chunk-\(index)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        continuation.resume(returning: outputURL)
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: TranscriptionError.audioPreparationFailed(
                        session.error?.localizedDescription ?? "Couldn't split the audio."))
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }
}
