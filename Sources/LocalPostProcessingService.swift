import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether on-device cleanup (Apple's Foundation Models) can run right now.
enum LocalCleanupAvailability: Equatable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unsupportedOS      // built/running on < macOS 26
    case frameworkMissing   // built without the FoundationModels SDK

    /// Short, friendly explanation for Settings.
    var statusMessage: String {
        switch self {
        case .available:
            return "On-device AI ready — cleanup works offline."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to enable offline cleanup."
        case .deviceNotEligible:
            return "This Mac can't run Apple Intelligence, so offline cleanup is unavailable."
        case .modelNotReady:
            return "Apple Intelligence is still preparing — try again shortly."
        case .unsupportedOS:
            return "Offline cleanup needs macOS 26 or later."
        case .frameworkMissing:
            return "Offline cleanup isn't available in this build."
        }
    }
}

enum LocalPostProcessingError: LocalizedError {
    case unavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device cleanup is unavailable."
        case .generationFailed(let message):
            return "On-device cleanup failed: \(message)"
        }
    }
}

/// On-device text cleanup and Edit Mode transforms using Apple's Foundation
/// Models (the same model behind Apple Intelligence). Runs fully offline. Mirrors
/// the shapes of `PostProcessingService` so AppState can route to either engine.
struct LocalPostProcessingService {
    static var availability: LocalCleanupAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
                case .deviceNotEligible: return .deviceNotEligible
                case .modelNotReady: return .modelNotReady
                @unknown default: return .modelNotReady
                }
            @unknown default:
                return .modelNotReady
            }
        } else {
            return .unsupportedOS
        }
        #else
        return .frameworkMissing
        #endif
    }

    static var isAvailable: Bool { availability == .available }

    /// Clean up a raw dictation transcript (grammar, filler, punctuation, etc.).
    func cleanup(
        transcript: String,
        contextSummary: String,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = Self.cleanupInstructions(
                customSystemPrompt: customSystemPrompt,
                customVocabulary: customVocabulary,
                outputLanguage: outputLanguage,
                contextSummary: contextSummary
            )
            return try await Self.generate(instructions: instructions, prompt: transcript)
        }
        #endif
        throw LocalPostProcessingError.unavailable
    }

    /// Edit Mode: transform the selected text per a spoken instruction.
    func transform(
        selectedText: String,
        voiceCommand: String,
        customVocabulary: String,
        outputLanguage: String
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = Self.transformInstructions(
                customVocabulary: customVocabulary,
                outputLanguage: outputLanguage
            )
            let prompt = """
            SELECTED_TEXT:
            \(selectedText)

            VOICE_COMMAND:
            \(voiceCommand)
            """
            return try await Self.generate(instructions: instructions, prompt: prompt)
        }
        #endif
        throw LocalPostProcessingError.unavailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generate(instructions: String, prompt: String) async throws -> String {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw LocalPostProcessingError.generationFailed(error.localizedDescription)
        }
    }
    #endif

    private static func cleanupInstructions(
        customSystemPrompt: String,
        customVocabulary: String,
        outputLanguage: String,
        contextSummary: String
    ) -> String {
        let base = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PostProcessingService.defaultSystemPrompt
            : customSystemPrompt
        var parts = [base]
        let vocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            parts.append("Preserve and correctly spell these custom terms when they are spoken: \(vocab)")
        }
        let lang = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty {
            parts.append("Write the cleaned output in \(lang).")
        }
        let context = contextSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            parts.append("Context (formatting/spelling hint only, do not add its content): \(context)")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func transformInstructions(
        customVocabulary: String,
        outputLanguage: String
    ) -> String {
        var parts = ["""
        You transform highlighted text according to a spoken editing command.
        Treat SELECTED_TEXT as the only source material to transform.
        Treat VOICE_COMMAND as the user's instruction for how to transform SELECTED_TEXT.
        Return only the replacement text — no explanations, no markdown, no quotes.
        Preserve meaning unless the command asks to change it.
        """]
        let vocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            parts.append("Preserve and correctly spell these custom terms: \(vocab)")
        }
        let lang = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty {
            parts.append("Write the output in \(lang).")
        }
        return parts.joined(separator: "\n\n")
    }
}
