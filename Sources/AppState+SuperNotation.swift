import AppKit

// MARK: - SuperNotation orchestration
//
// Drives an annotation session end-to-end: a dedicated hotkey starts/stops it,
// the mic records a spoken walkthrough, circling the cursor captures annotated
// screenshots, and on stop everything is woven into a ready-to-paste prompt
// (copied to the clipboard) and saved as a browsable session. Lives in an
// extension to keep it isolated from — and unable to disturb — dictation.
extension AppState {

    private static let annotationTapThreshold: CFTimeInterval = 0.4

    // MARK: Shortcut configuration

    /// Validate + assign the annotation shortcut. Returns an error string if it
    /// clashes with a dictation shortcut, else nil.
    @discardableResult
    func setAnnotationShortcut(_ binding: ShortcutBinding) -> String? {
        let binding = binding.normalizedForStorageMigration()
        if !binding.isDisabled {
            if binding.conflicts(with: holdShortcut) { return "This shortcut is already used by Hold to Talk." }
            if binding.conflicts(with: toggleShortcut) { return "This shortcut is already used by Tap to Toggle." }
            if binding.conflicts(with: copyAgainShortcut) { return "This shortcut is already used by Paste Again." }
        }
        if binding.isCustom { savedAnnotationCustomShortcut = binding }
        annotationShortcut = binding
        return nil
    }

    // MARK: Tap-or-hold key handling (mirrors the dictation unified machine)

    func annotationKeyDown() {
        if isAnnotating {
            // Tapping again while latched stops the session; a hold-in-progress
            // ignores extra downs.
            if annotationLatched { finishAnnotation() }
            return
        }
        annotationActivationMonotonic = CACurrentMediaTime()
        annotationPendingHold = true
        annotationLatched = false
        startAnnotation()
        if !isAnnotating { annotationPendingHold = false } // start was refused
    }

    func annotationKeyUp() {
        guard isAnnotating, annotationPendingHold else { return }
        annotationPendingHold = false
        let held = CACurrentMediaTime() - annotationActivationMonotonic
        if held < Self.annotationTapThreshold {
            annotationLatched = true   // a tap: keep running until the next tap
        } else {
            finishAnnotation()         // a hold: release ends the session
        }
    }

    /// Start if idle, stop if running (used by the menu bar item).
    func toggleAnnotation() {
        if isAnnotating {
            annotationLatched = false
            annotationPendingHold = false
            finishAnnotation()
        } else {
            startAnnotation()
            annotationLatched = true    // started deliberately, not via key-hold
            annotationPendingHold = false
        }
    }

    // MARK: Session lifecycle

    func startAnnotation() {
        guard !isAnnotating else { return }
        guard !isRecording, !isTranscribing else {
            statusHUD.show("Finish dictation first", systemImage: "exclamationmark.circle")
            return
        }
        guard AnnotationCapture.hasScreenPermission() else {
            AnnotationCapture.requestScreenPermission()
            statusHUD.show("Allow Screen Recording for \(AppName.displayName), then try again",
                           systemImage: "rectangle.dashed.badge.record", duration: 4)
            return
        }

        let date = Date()
        let id = Self.annotationFolderName(for: date)
        let folder = superNotationStore.makeSessionFolder(id: id)

        annotationSessionID = id
        annotationSessionFolder = folder
        annotationStartDate = date
        annotationStartMonotonic = CACurrentMediaTime()
        annotationShots = []
        annotationShotCounter = 0
        annotationFinishing = false

        mouseGestureMonitor.sensitivity = annotationSensitivity
        mouseGestureMonitor.onCircle = { [weak self] points, screen in
            self?.captureAnnotationShot(points: points, screen: screen)
        }

        do {
            let uid = (selectedMicrophoneID == "default" || selectedMicrophoneID.isEmpty) ? nil : selectedMicrophoneID
            try annotationRecorder.startRecording(deviceUID: uid)
        } catch {
            statusHUD.show("Couldn't start recording", systemImage: "exclamationmark.triangle.fill", duration: 3)
            return
        }

        isAnnotating = true
        annotationStatusDetail = ""
        mouseGestureMonitor.start()
        statusHUD.showProgress("Annotation on — talk & circle the issues", systemImage: "scribble.variable")
    }

    /// Captured when the user circles the cursor: screenshot the display, draw the
    /// circle, save it, and remember when it happened (for inline placement).
    func captureAnnotationShot(points: [CGPoint], screen: NSScreen) {
        guard isAnnotating, let folder = annotationSessionFolder else { return }
        let elapsed = CACurrentMediaTime() - annotationStartMonotonic
        annotationShotCounter += 1
        let n = annotationShotCounter
        let fileName = String(format: "shot-%02d.png", n)
        annotationShots.append(AnnotationShot(fileName: fileName, elapsedSeconds: elapsed, label: "Screenshot \(n)"))
        annotationStatusDetail = "\(n) screenshot\(n == 1 ? "" : "s")"
        statusHUD.showProgress("Annotation on · \(n) shot\(n == 1 ? "" : "s") captured", systemImage: "camera.viewfinder")

        let displayID = AnnotationCapture.displayID(for: screen)
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        let dest = folder.appendingPathComponent(fileName)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = AnnotationCapture.annotatedPNG(
                displayID: displayID, screenFrame: frame, scale: scale, path: points
            ) else { return }
            try? data.write(to: dest)
        }
    }

    func finishAnnotation() {
        guard isAnnotating, !annotationFinishing else { return }
        annotationFinishing = true
        isAnnotating = false
        annotationLatched = false
        annotationPendingHold = false
        mouseGestureMonitor.stop()

        let shots = annotationShots
        let duration = max(0.1, CACurrentMediaTime() - annotationStartMonotonic)
        let folder = annotationSessionFolder
        let sessionID = annotationSessionID
        let createdAt = annotationStartDate

        statusHUD.showProgress("Transcribing your walkthrough…", systemImage: "waveform")

        annotationRecorder.stopRecording { [weak self] url in
            DispatchQueue.main.async {
                Task { @MainActor in
                    await self?.finalizeAnnotation(audioURL: url, shots: shots, duration: duration,
                                                   folder: folder, sessionID: sessionID, createdAt: createdAt)
                }
            }
        }
    }

    @MainActor
    private func finalizeAnnotation(audioURL: URL?, shots: [AnnotationShot], duration: Double,
                                    folder: URL?, sessionID: String, createdAt: Date) async {
        defer {
            annotationFinishing = false
            annotationStatusDetail = ""
        }
        guard let folder else { return }

        // Transcribe the walkthrough (routes online/offline like everything else).
        var transcript = ""
        if let audioURL {
            do {
                transcript = try await transcribeAudioFile(at: audioURL)
            } catch {
                transcript = ""
            }
            let dest = folder.appendingPathComponent("audio.wav")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: audioURL, to: dest)
        }
        transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty && shots.isEmpty {
            statusHUD.show("Nothing captured", systemImage: "xmark.circle", duration: 2)
            superNotationStore.delete(AnnotationSession(
                id: sessionID, createdAt: createdAt, title: "", transcript: "",
                promptText: "", shots: [], folderName: sessionID, audioFileName: nil))
            return
        }

        let built = buildAnnotationPrompt(rawTranscript: transcript, shots: shots,
                                          duration: duration, folderURL: folder)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(built.prompt, forType: .string)

        let session = AnnotationSession(
            id: sessionID, createdAt: createdAt, title: built.title,
            transcript: built.markeredTranscript, promptText: built.prompt,
            shots: shots, folderName: sessionID,
            audioFileName: audioURL != nil ? "audio.wav" : nil
        )
        superNotationStore.save(session)
        reloadSuperNotationSessions()

        let n = shots.count
        statusHUD.show("Prompt copied · \(n) screenshot\(n == 1 ? "" : "s")",
                       systemImage: "checkmark.circle.fill", duration: 2.6)
    }

    // MARK: Prompt assembly

    /// Weave screenshot markers into the transcript by when each was taken, and
    /// wrap it with the preamble + folder path into a paste-ready prompt.
    func buildAnnotationPrompt(rawTranscript: String, shots: [AnnotationShot],
                               duration: Double, folderURL: URL)
        -> (prompt: String, markeredTranscript: String, title: String) {

        let words = rawTranscript.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let n = words.count

        var insertions: [Int: [AnnotationShot]] = [:]
        for shot in shots.sorted(by: { $0.elapsedSeconds < $1.elapsedSeconds }) {
            let fraction = duration > 0 ? min(1, max(0, shot.elapsedSeconds / duration)) : 1
            let index = max(0, min(n, Int((Double(n) * fraction).rounded())))
            insertions[index, default: []].append(shot)
        }

        func markerLine(_ shot: AnnotationShot) -> String {
            "\n\n[\(shot.label): \(shot.fileName) — the red circle shows where I'm pointing]\n\n"
        }

        var markered = ""
        for i in 0...n {
            if let here = insertions[i] {
                for shot in here { markered += markerLine(shot) }
            }
            if i < n {
                if !markered.isEmpty, !markered.hasSuffix("\n"), !markered.hasSuffix(" ") { markered += " " }
                markered += words[i]
            }
        }
        markered = markered.trimmingCharacters(in: .whitespacesAndNewlines)
        if markered.isEmpty {
            // No speech captured — still list the screenshots so they're usable.
            markered = shots.map { "\($0.label): \($0.fileName) — the red circle shows where I'm pointing." }
                .joined(separator: "\n")
            if markered.isEmpty { markered = "(no narration captured)" }
        }

        let fileList = shots.isEmpty ? "(none)" : shots.map(\.fileName).joined(separator: ", ")

        let prompt = """
        \(annotationPreamble)

        Screenshots folder:
        \(folderURL.path)

        Screenshots: \(fileList)

        ───────────────────────────  walkthrough  ───────────────────────────

        \(markered)

        ──────────────────────────────────────────────────────────────────────

        (Open the screenshots in the folder above to see exactly what I'm pointing at — the red circle marks the spot.)
        """

        // Title = first words spoken, else the date.
        let firstWords = rawTranscript.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(8).joined(separator: " ")
        let title: String
        if firstWords.isEmpty {
            title = "Annotation · \(shots.count) shot\(shots.count == 1 ? "" : "s")"
        } else {
            let wordCount = rawTranscript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
            title = firstWords + (wordCount > 8 ? "…" : "")
        }

        return (prompt, markered, title)
    }

    // MARK: Gallery helpers

    func reloadSuperNotationSessions() {
        superNotationSessions = superNotationStore.loadAll()
    }

    func deleteSuperNotation(_ session: AnnotationSession) {
        superNotationStore.delete(session)
        reloadSuperNotationSessions()
    }

    func copySuperNotationPrompt(_ session: AnnotationSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.promptText, forType: .string)
        statusHUD.show("Prompt copied", systemImage: "doc.on.doc", duration: 1.6)
    }

    func revealSuperNotationFolder(_ session: AnnotationSession) {
        NSWorkspace.shared.activateFileViewerSelecting([superNotationStore.sessionFolder(for: session)])
    }

    func openSuperNotationRootFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([superNotationStore.rootDirectory])
    }

    func shotURL(_ shot: AnnotationShot, in session: AnnotationSession) -> URL {
        superNotationStore.shotURL(shot, in: session)
    }

    static func annotationFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
