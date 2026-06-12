import SwiftUI
import AppKit

// MARK: - SuperNotation tab

/// The "SuperNotation" settings tab: explains/configures the AI annotation
/// feature and shows a gallery of every prompt you've recorded, each with
/// screenshot thumbnails. Click a card to read the full prompt and screenshots.
struct SuperNotationView: View {
    @EnvironmentObject var appState: AppState
    @State private var selected: AnnotationSession?
    @State private var annotationCapturing = false
    @State private var annotationValidation: String?
    @State private var captureCapturing = false
    @State private var captureValidation: String?
    @State private var permissionTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                howItWorksCard
                setupCard
                galleryCard
            }
            .padding(24)
        }
        .onAppear { appState.reloadSuperNotationSessions() }
        .sheet(item: $selected) { session in
            SuperNotationDetailView(session: session)
                .environmentObject(appState)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("SuperNotation", systemImage: "scribble.variable")
                    .font(.title2.bold())
                Text("Talk through your app while circling the cursor at the problems. \(AppName.displayName) captures annotated screenshots, then copies one tidy prompt — narration + screenshots — straight to your clipboard for your AI coder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            startStopButton
        }
    }

    private var startStopButton: some View {
        VStack(spacing: 6) {
            Button {
                appState.toggleAnnotation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.isAnnotating ? "stop.circle.fill" : "record.circle")
                    Text(appState.isAnnotating ? "Stop & Copy" : "Start Annotation")
                }
                .frame(minWidth: 130)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(appState.isAnnotating ? .red : .accentColor)

            if appState.isAnnotating {
                Label(appState.annotationStatusDetail.isEmpty ? "Listening…" : appState.annotationStatusDetail,
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: How it works

    private var howItWorksCard: some View {
        SettingsCard("How it works", icon: "lightbulb.fill") {
            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, "Start a session", "Press your annotation shortcut (tap to toggle, or hold), or click Start Annotation.")
                stepRow(2, "Talk and circle", "Describe each issue out loud. Circle or scribble your cursor over the spot — that snaps a screenshot with a red mark where you pointed.")
                stepRow(3, "Stop", "Tap the shortcut again (or release the hold). Your walkthrough is transcribed, the screenshots are slotted in at the right moments, and the whole prompt is copied to your clipboard.")
                stepRow(4, "Paste into your AI coder", "The prompt tells the agent where the screenshots live on disk, so it can open them. Every session is saved below.")
            }
        }
    }

    private func stepRow(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Setup

    private var setupCard: some View {
        SettingsCard("Setup", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                permissionRow

                VStack(alignment: .leading, spacing: 6) {
                    Text("Annotation shortcut")
                        .font(.caption.weight(.semibold))
                    Text("A dedicated key, separate from dictation. Tap to toggle, or press and hold.")
                        .font(.caption).foregroundStyle(.secondary)
                    shortcutRows
                    if let annotationValidation, !annotationValidation.isEmpty {
                        Label(annotationValidation, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-capture when you circle the cursor", isOn: $appState.annotationAutoCapture)
                    Text(appState.annotationAutoCapture
                        ? "Circle or scribble the cursor over a spot and it snaps a screenshot automatically."
                        : "Off — screenshots are taken only when you press the capture shortcut below, so you choose exactly where each one goes.")
                        .font(.caption).foregroundStyle(.secondary)

                    if appState.annotationAutoCapture {
                        Text("Trigger sensitivity")
                            .font(.caption.weight(.semibold))
                            .padding(.top, 2)
                        Picker("", selection: $appState.annotationSensitivity) {
                            ForEach(AnnotationSensitivity.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("How much circling it takes to snap a screenshot. Higher is easier to trigger.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Capture screenshot shortcut")
                        .font(.caption.weight(.semibold))
                    Text("Press this during a session to snap a screenshot with a circle around your pointer — choose each one yourself. Works whether or not auto-capture is on.")
                        .font(.caption).foregroundStyle(.secondary)
                    captureShortcutRows
                    if let captureValidation, !captureValidation.isEmpty {
                        Label(captureValidation, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Draw the mouse path too", isOn: $appState.annotationShowPath)
                    Text("Off by default — each screenshot gets a clean circle or box around the spot you circled. Turn on to also draw the line of exactly where your cursor moved.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Prompt preamble")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Reset to default") {
                            appState.annotationPreamble = AppState.defaultAnnotationPreamble
                        }
                        .controlSize(.small)
                        .disabled(appState.annotationPreamble == AppState.defaultAnnotationPreamble)
                    }
                    Text("Added to the top of every copied prompt, before your narration and the screenshot list.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $appState.annotationPreamble)
                        .font(.system(size: 12))
                        .frame(minHeight: 90, maxHeight: 140)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved to")
                            .font(.caption.weight(.semibold))
                        Text(appState.superNotationStore.rootDirectory.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Reveal in Finder") { appState.openSuperNotationRootFolder() }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        let _ = permissionTick // re-read permission when we bump this
        if !AnnotationCapture.hasScreenPermission() {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording permission needed")
                        .font(.caption.weight(.semibold))
                    Text("Annotation screenshots require Screen Recording access for \(AppName.displayName).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Request Access") {
                            AnnotationCapture.requestScreenPermission()
                            permissionTick += 1
                        }
                        .controlSize(.small)
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private var shortcutRows: some View {
        VStack(spacing: 6) {
            ShortcutPresetRow(
                title: "Disabled",
                isSelected: appState.annotationShortcut.isDisabled,
                action: { annotationValidation = appState.setAnnotationShortcut(.disabled) }
            )
            ForEach(ShortcutPreset.allCases) { preset in
                ShortcutPresetRow(
                    title: preset.title,
                    isSelected: appState.annotationShortcut == preset.binding,
                    action: { annotationValidation = appState.setAnnotationShortcut(preset.binding) }
                )
            }
            ShortcutCaptureRow(
                savedBinding: appState.savedAnnotationCustomShortcut,
                isSelected: appState.annotationShortcut.isCustom,
                isCapturing: $annotationCapturing,
                onSelectSaved: { binding in annotationValidation = appState.setAnnotationShortcut(binding) },
                onCapture: { binding in annotationValidation = appState.setAnnotationShortcut(binding) }
            )
        }
        .onChange(of: annotationCapturing) { capturing in
            if capturing { appState.suspendHotkeyMonitoringForShortcutCapture() }
            else { appState.resumeHotkeyMonitoringAfterShortcutCapture() }
        }
    }

    private var captureShortcutRows: some View {
        VStack(spacing: 6) {
            ShortcutPresetRow(
                title: "Disabled",
                isSelected: appState.annotationCaptureShortcut.isDisabled,
                action: { captureValidation = appState.setAnnotationCaptureShortcut(.disabled) }
            )
            ForEach(ShortcutPreset.allCases) { preset in
                ShortcutPresetRow(
                    title: preset.title,
                    isSelected: appState.annotationCaptureShortcut == preset.binding,
                    action: { captureValidation = appState.setAnnotationCaptureShortcut(preset.binding) }
                )
            }
            ShortcutCaptureRow(
                savedBinding: appState.savedAnnotationCaptureCustomShortcut,
                isSelected: appState.annotationCaptureShortcut.isCustom,
                isCapturing: $captureCapturing,
                onSelectSaved: { binding in captureValidation = appState.setAnnotationCaptureShortcut(binding) },
                onCapture: { binding in captureValidation = appState.setAnnotationCaptureShortcut(binding) }
            )
        }
        .onChange(of: captureCapturing) { capturing in
            if capturing { appState.suspendHotkeyMonitoringForShortcutCapture() }
            else { appState.resumeHotkeyMonitoringAfterShortcutCapture() }
        }
    }

    // MARK: Gallery

    private var galleryCard: some View {
        SettingsCard("Your SuperNotations", icon: "rectangle.stack.fill") {
            if appState.superNotationSessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No annotations yet")
                        .font(.callout.weight(.semibold))
                    Text("Start a session and your prompts will collect here, each with its screenshots.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(appState.superNotationSessions) { session in
                        SuperNotationCard(session: session)
                            .onTapGesture { selected = session }
                            .contextMenu {
                                Button("Copy Prompt") { appState.copySuperNotationPrompt(session) }
                                Button("Reveal in Finder") { appState.revealSuperNotationFolder(session) }
                                Divider()
                                Button("Delete", role: .destructive) { appState.deleteSuperNotation(session) }
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Gallery card

private struct SuperNotationCard: View {
    @EnvironmentObject var appState: AppState
    let session: AnnotationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Color(nsColor: .controlBackgroundColor))
                if let first = session.shots.first, let image = loadImage(first) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                if session.shotCount > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label("\(session.shotCount)", systemImage: "camera.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                }
            }
            .frame(height: 120)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Annotation" : session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(Self.dateFormatter.string(from: session.createdAt))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }

    private func loadImage(_ shot: AnnotationShot) -> NSImage? {
        NSImage(contentsOf: appState.shotURL(shot, in: session))
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Detail sheet

struct SuperNotationDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let session: AnnotationSession
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "Annotation" : session.title)
                        .font(.headline).lineLimit(1)
                    Text("\(SuperNotationCard.dateFormatter.string(from: session.createdAt)) · \(session.shotCount) screenshot\(session.shotCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Button { appState.copySuperNotationPrompt(session) } label: {
                            Label("Copy Prompt", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { appState.revealSuperNotationFolder(session) } label: {
                            Label("Reveal Folder", systemImage: "folder")
                        }
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    if !session.shots.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Screenshots")
                                .font(.subheadline.weight(.semibold))
                            ForEach(session.shots) { shot in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(shot.label).font(.caption.weight(.semibold))
                                    if let image = NSImage(contentsOf: appState.shotURL(shot, in: session)) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                                    } else {
                                        Text("(\(shot.fileName) — image unavailable)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt")
                            .font(.subheadline.weight(.semibold))
                        Text(session.promptText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 640)
        .alert("Delete this SuperNotation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                appState.deleteSuperNotation(session)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes its folder, screenshots, and prompt.")
        }
    }
}
