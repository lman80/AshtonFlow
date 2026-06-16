import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

/// A window where the user drags in (or picks) an audio or video file and gets
/// the transcribed text. Reuses the app's TranscriptionService. Video files (and
/// other containers) have their audio extracted to m4a first via AVFoundation.
struct TranscribeAudioView: View {
    @EnvironmentObject var appState: AppState

    private enum Phase {
        case idle
        case preparing
        case transcribing
        case done(String)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var fileName: String = ""
    @State private var isTargeted = false
    @State private var usedOffline = false
    @State private var progress: Double = 0
    @State private var progressDetail: String = ""
    @State private var copiedMessage: String?
    @State private var currentTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe Audio")
                .font(.title2.bold())
            Text("Drag in an audio or video file, or choose one. The text appears below, is copied to your clipboard, and saved to your history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            dropZone

            statusAndResult

            historySection

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 2, dash: [8])
            )
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
            )
            .frame(height: 130)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(isTargeted ? "Drop to transcribe" : "Drag an audio or video file here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose File…") { chooseFile() }
                        .controlSize(.small)
                }
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    // MARK: - Status + result

    @ViewBuilder
    private var statusAndResult: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .preparing, .transcribing:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if isTranscribingPhase, progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text("\(Int((progress * 100).rounded()))%\(progressDetail.isEmpty ? "" : " · \(progressDetail)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }

        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Transcribed \(fileName)\(usedOffline ? " · on-device" : "")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        copyToClipboard(text)
                        flashCopied("Copied transcription")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    Button {
                        copyToClipboard(appState.meetingNotesPrompt + "\n\n" + text)
                        flashCopied("Copied with AI prompt — paste into ChatGPT")
                    } label: {
                        Label("Copy with AI Prompt", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Copies the transcript with your meeting-notes prompt on top, ready to paste into ChatGPT.")
                }
                ScrollView {
                    Text(text.isEmpty ? "(No speech detected)" : text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                )
                if let copiedMessage {
                    Label(copiedMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Copied to clipboard and saved to History.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isTranscribingPhase: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    private var progressLabel: String {
        switch phase {
        case .preparing: return "Extracting audio from \(fileName)…"
        case .transcribing: return usedOffline
            ? "Transcribing \(fileName) on-device…"
            : "Transcribing \(fileName) on the cloud…"
        default: return ""
        }
    }

    // MARK: - History

    private var fileHistory: [PipelineHistoryItem] {
        appState.pipelineHistory
            .filter { $0.contextSummary.hasPrefix("Transcribed file:") }
            .sorted { $0.timestamp > $1.timestamp }
    }

    @ViewBuilder
    private var historySection: some View {
        if !fileHistory.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent transcriptions")
                    .font(.headline)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(fileHistory.prefix(15)) { item in
                            Button {
                                fileName = item.contextWindowTitle ?? "transcription"
                                usedOffline = false
                                phase = .done(item.postProcessedTranscript)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.contextWindowTitle ?? "Transcription")
                                            .font(.callout)
                                            .lineLimit(1)
                                        Text(item.postProcessedTranscript)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button {
                                        copyToClipboard(item.postProcessedTranscript)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Copy")
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 170)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            }
        }
    }

    // MARK: - File intake

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                start(url: url)
            }
        }
        return true
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mpeg4Audio, .mp3, .wav, .aiff]
        if panel.runModal() == .OK, let url = panel.url {
            start(url: url)
        }
    }

    private func start(url: URL) {
        currentTask?.cancel()
        fileName = url.lastPathComponent
        currentTask = Task { await run(url: url) }
    }

    @MainActor
    private func run(url: URL) async {
        progress = 0
        progressDetail = ""
        usedOffline = appState.isOfflineActive
        var prepared: PreparedAudio?

        let onProgress: @Sendable (Double, Int, Int) -> Void = { fraction, done, total in
            Task { @MainActor in
                progress = fraction
                progressDetail = total > 1 ? "part \(done) of \(total)" : ""
            }
        }

        do {
            let raw: String
            if usedOffline {
                // On-device engine needs a prepared audio file (extract from video).
                phase = .preparing
                let preparedAudio = try await AudioFilePreparer.prepare(url)
                prepared = preparedAudio
                if Task.isCancelled { preparedAudio.cleanup(); return }
                phase = .transcribing
                raw = try await appState.transcribeAudioFileWithProgress(at: preparedAudio.url, onProgress: onProgress)
            } else {
                // Cloud: the chunked transcriber reads the original directly
                // (splitting long files + extracting audio from video itself), so
                // there's no slow whole-file pre-extract step.
                phase = .transcribing
                raw = try await appState.transcribeAudioFileWithProgress(at: url, onProgress: onProgress)
            }
            if Task.isCancelled { prepared?.cleanup(); return }

            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            copyToClipboard(text)
            appState.recordFileTranscription(text: text, fileName: url.lastPathComponent)
            phase = .done(text)
            prepared?.cleanup()
        } catch is CancellationError {
            prepared?.cleanup()
        } catch {
            prepared?.cleanup()
            phase = .failed(error.localizedDescription)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func flashCopied(_ message: String) {
        copiedMessage = message
        let token = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if copiedMessage == token { copiedMessage = nil }
        }
    }
}

// MARK: - Audio preparation

/// The result of preparing a file for transcription. If `isTemporary`, the file
/// was transcoded into a temp location and should be cleaned up afterward.
private struct PreparedAudio {
    let url: URL
    let isTemporary: Bool

    func cleanup() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private enum AudioPreparationError: LocalizedError {
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let message):
            return "Couldn't read audio from this file. \(message)"
        }
    }
}

private enum AudioFilePreparer {
    /// Formats the transcription API accepts directly, so no transcoding needed.
    private static let directlySupportedExtensions: Set<String> = ["mp3", "wav", "m4a", "flac"]

    static func prepare(_ url: URL) async throws -> PreparedAudio {
        let ext = url.pathExtension.lowercased()
        if directlySupportedExtensions.contains(ext) {
            return PreparedAudio(url: url, isTemporary: false)
        }
        // Video (mp4/mov/…) or any other container AVFoundation can read:
        // extract the audio track to a compact m4a that the API accepts.
        let outputURL = try await exportToM4A(from: url)
        return PreparedAudio(url: outputURL, isTemporary: true)
    }

    private static func exportToM4A(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioPreparationError.extractionFailed("This format isn't supported.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        session.outputURL = outputURL
        session.outputFileType = .m4a

        return try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    let message = session.error?.localizedDescription ?? "The file may have no audio track."
                    continuation.resume(throwing: AudioPreparationError.extractionFailed(message))
                }
            }
        }
    }
}
