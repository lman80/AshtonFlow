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
    @State private var currentTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe Audio")
                .font(.title2.bold())
            Text("Drag in an audio or video file, or choose one. The text appears below, is copied to your clipboard, and is saved to History.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            dropZone

            statusAndResult

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
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
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progressLabel)
                    .foregroundStyle(.secondary)
            }

        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Transcribed \(fileName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Spacer()
                    Button {
                        copyToClipboard(text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
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
                Text("Copied to clipboard and saved to History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var progressLabel: String {
        switch phase {
        case .preparing: return "Preparing \(fileName)…"
        case .transcribing: return "Transcribing \(fileName)…"
        default: return ""
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
        phase = .preparing
        var prepared: PreparedAudio?
        do {
            let preparedAudio = try await AudioFilePreparer.prepare(url)
            prepared = preparedAudio
            if Task.isCancelled { preparedAudio.cleanup(); return }

            phase = .transcribing
            let raw = try await appState.transcribeAudioFile(at: preparedAudio.url)
            if Task.isCancelled { preparedAudio.cleanup(); return }

            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            copyToClipboard(text)
            appState.recordFileTranscription(text: text, fileName: url.lastPathComponent)
            phase = .done(text)
            preparedAudio.cleanup()
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
