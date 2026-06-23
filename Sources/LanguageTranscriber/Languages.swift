import Foundation

struct Language: Identifiable, Hashable {
    let code: String          // ISO 639-1, what OpenAI expects
    var id: String { code }

    var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}

enum Languages {
    /// Common bilingual partners. Ordered roughly by frequency-of-use in tech calls.
    static let common: [Language] = [
        Language(code: "pt"),   // Portuguese
        Language(code: "es"),   // Spanish
        Language(code: "fr"),   // French
        Language(code: "de"),   // German
        Language(code: "it"),   // Italian
        Language(code: "nl"),   // Dutch
        Language(code: "ja"),   // Japanese
        Language(code: "zh"),   // Chinese
        Language(code: "ko"),   // Korean
        Language(code: "hi"),   // Hindi
        Language(code: "ar"),   // Arabic
        Language(code: "ru"),   // Russian
        Language(code: "tr"),   // Turkish
        Language(code: "pl"),   // Polish
        Language(code: "vi"),   // Vietnamese
        Language(code: "th"),   // Thai
        Language(code: "sv"),   // Swedish
        Language(code: "he"),   // Hebrew
        Language(code: "el"),   // Greek
        Language(code: "uk")    // Ukrainian
    ]

    /// Look up a Language by ISO code, falling back to a synthesized entry so unknown codes
    /// (e.g. anything the user pastes into config.json) still work.
    static func find(_ code: String) -> Language {
        if let known = common.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            return known
        }
        return Language(code: code.lowercased())
    }
}
