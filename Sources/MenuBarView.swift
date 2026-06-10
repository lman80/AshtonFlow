import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var recentHistoryItems: [PipelineHistoryItem] {
        Array(appState.pipelineHistory.filter { !transcriptText(for: $0).isEmpty }.prefix(10))
    }

    private func transcriptText(for item: PipelineHistoryItem) -> String {
        let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        return item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFull(for item: PipelineHistoryItem) -> String {
        if !item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    private func transcriptSnippet(for item: PipelineHistoryItem) -> String {
        let text = transcriptText(for: item)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "(no transcript)" }
        return text.count > 48 ? String(text.prefix(48)) + "..." : text
    }

    private func copyTranscriptToPasteboard(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func openRunLog() {
        appState.selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(AppName.displayName) v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            Divider()

            if !appState.hasScreenRecordingPermission {
                Button {
                    appState.requestScreenCapturePermission()
                } label: {
                    Label("Screen Recording Permission Needed", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)

                Divider()
            }

            // Accessibility warning
            if !appState.hasAccessibility {
                Button {
                    appState.showAccessibilityAlert()
                } label: {
                    Label("Accessibility Required", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.red)

                Divider()
            }

            // Status
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label(appState.debugStatusMessage, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Text(appState.shortcutStatusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            // Manual toggle
            Button(appState.isRecording ? "Stop Recording" : "Start Dictating") {
                appState.toggleRecording()
            }
            .disabled(appState.isTranscribing)

            Button("Transcribe Audio...") {
                NotificationCenter.default.post(name: .showTranscribeAudio, object: nil)
            }

            if appState.isAnnotating {
                Button("Stop Annotation & Copy Prompt") { appState.toggleAnnotation() }
            } else if !appState.annotationShortcut.isDisabled {
                Button("Start Annotation") { appState.toggleAnnotation() }
            }

            Toggle("Offline Mode (local)", isOn: $appState.offlineModeEnabled)

            if !appState.offlineModeEnabled && appState.autoOfflineActive {
                Text("No internet — using offline for now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }

            if let hotkeyError = appState.hotkeyMonitoringErrorMessage {
                Divider()
                Text(hotkeyError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            Divider()

            if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                Button(appState.copyAgainShortcut.isDisabled
                    ? "Paste Again"
                    : "Paste Again  (\(appState.copyAgainShortcut.displayName))") {
                    appState.copyLastTranscriptToPasteboard()
                }

                let truncatedTranscript = appState.lastTranscript.count > 35
                    ? String(appState.lastTranscript.prefix(35)) + "…"
                    : appState.lastTranscript
                Text("\u{201C}\(truncatedTranscript)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .lineLimit(4)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            Menu("History") {
                if recentHistoryItems.isEmpty {
                    Text("No transcripts yet")
                } else {
                    ForEach(recentHistoryItems) { item in
                        let transcript = transcriptText(for: item)
                        Button {
                            copyTranscriptToPasteboard(transcriptFull(for: item))
                        } label: {
                            Text(transcriptSnippet(for: item))
                        }
                        .disabled(transcript.isEmpty)
                    }

                    Divider()
                }

                Button("Open Run Log") {
                    openRunLog()
                }
            }

            Divider()

            Button("Settings") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }

            Button("Send Feedback…") {
                NotificationCenter.default.post(name: .showSendFeedback, object: nil)
            }

            if updateManager.updateAvailable {
                Divider()

                switch updateManager.updateStatus {
                case .downloading:
                    VStack(spacing: 4) {
                        Text("Downloading update... \(Int((updateManager.downloadProgress ?? 0) * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        ProgressView(value: updateManager.downloadProgress ?? 0)
                            .progressViewStyle(.linear)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                case .installing, .readyToRelaunch:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing update...")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                default:
                    Button {
                        updateManager.showUpdateAlert()
                    } label: {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                }
            }

            Divider()

            Button("Quit \(AppName.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}
