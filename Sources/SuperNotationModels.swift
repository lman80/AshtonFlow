import Foundation

// MARK: - Models

/// One annotated screenshot captured during a SuperNotation session. The red
/// mark on the image shows where the user was pointing when they circled.
struct AnnotationShot: Codable, Identifiable, Hashable {
    var id: String { fileName }
    let fileName: String        // e.g. "shot-01.png" (lives in the session folder)
    let elapsedSeconds: Double  // when it was captured, measured from session start
    var label: String           // e.g. "Screenshot 1"
}

/// A saved "SuperNotation": a spoken walkthrough of an app with inline
/// screenshots, turned into a ready-to-paste prompt for an AI coding agent.
/// Each session is a self-contained folder on disk so Claude Code (and the
/// user) can open the screenshots directly.
struct AnnotationSession: Codable, Identifiable, Hashable {
    let id: String              // UUID string; also the on-disk folder name
    let createdAt: Date
    var title: String           // short label for the gallery (first words spoken)
    var transcript: String      // raw spoken text, with inline screenshot markers
    var promptText: String      // the full prompt that was copied to the clipboard
    var shots: [AnnotationShot]
    var folderName: String      // subfolder under the SuperNotation root
    var audioFileName: String?  // optional saved audio ("audio.wav")

    var shotCount: Int { shots.count }
}

// MARK: - Store

/// Persists annotation sessions as plain folders under
/// `~/Documents/SuperNotation/<id>/` — each containing the screenshots,
/// a `prompt.md`, and a `session.json`. Stored as ordinary files (not a
/// database) precisely so an AI coding agent can read them directly.
final class SuperNotationStore {
    static let shared = SuperNotationStore()

    let rootDirectory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        rootDirectory = docs.appendingPathComponent("SuperNotation", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    /// Absolute folder for a session.
    func sessionFolder(for session: AnnotationSession) -> URL {
        rootDirectory.appendingPathComponent(session.folderName, isDirectory: true)
    }

    /// Absolute URL of one of a session's screenshots.
    func shotURL(_ shot: AnnotationShot, in session: AnnotationSession) -> URL {
        sessionFolder(for: session).appendingPathComponent(shot.fileName)
    }

    /// Create a fresh, empty session folder and return its id + url.
    @discardableResult
    func makeSessionFolder(id: String) -> URL {
        let url = rootDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write `prompt.md` + `session.json` into the session's folder.
    func save(_ session: AnnotationSession) {
        let folder = sessionFolder(for: session)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? session.promptText.data(using: .utf8)?.write(to: folder.appendingPathComponent("prompt.md"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(session) {
            try? data.write(to: folder.appendingPathComponent("session.json"))
        }
    }

    /// Load every saved session, newest first, by scanning the root folder.
    func loadAll() -> [AnnotationSession] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sessions: [AnnotationSession] = []
        for entry in entries {
            let jsonURL = entry.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let session = try? decoder.decode(AnnotationSession.self, from: data) else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ session: AnnotationSession) {
        try? FileManager.default.removeItem(at: sessionFolder(for: session))
    }
}
