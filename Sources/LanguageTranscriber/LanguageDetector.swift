import Foundation
import NaturalLanguage

/// Detects the dominant non-English language from accumulated source-language transcript text.
///
/// Uses Apple's `NLLanguageRecognizer` (local, no API call). Locks onto a language once we have
/// enough text and a confident non-English hypothesis, so we don't keep flipping mid-conversation.
final class LanguageDetector {
    /// ISO 639-1 code of the locked "other" language, if any.
    private(set) var lockedLanguage: String?

    private var accumulated: String = ""

    /// Minimum number of characters in the source transcript before we attempt detection.
    private let minChars: Int = 25
    /// Minimum confidence (0…1) for the dominant non-English language hypothesis.
    private let minConfidence: Double = 0.65

    /// Feed accumulated source-language transcript text. Returns the locked ISO code on the
    /// first call where lock-in occurs; nil otherwise.
    func ingest(_ delta: String) -> String? {
        if lockedLanguage != nil { return nil }
        accumulated += delta
        guard accumulated.count >= minChars else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(accumulated)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)

        // Pick the most confident hypothesis that isn't English and clears the threshold.
        let ranked = hypotheses.sorted { $0.value > $1.value }
        for (language, confidence) in ranked {
            guard language != .english else { continue }
            guard confidence >= minConfidence else { continue }
            let code = language.rawValue       // ISO 639-1, e.g. "pt", "es", "ja"
            lockedLanguage = code
            return code
        }
        return nil
    }

    func reset() {
        lockedLanguage = nil
        accumulated = ""
    }

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}
