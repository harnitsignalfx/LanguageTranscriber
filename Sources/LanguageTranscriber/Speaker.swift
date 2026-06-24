import Foundation

/// Which language the speaker actually used for this utterance. Determined by running a
/// third (transcription-only) realtime session in parallel with the two translation
/// sessions and feeding its source-language transcript through `NLLanguageRecognizer`.
enum OriginalLanguage: String, Equatable {
    case english
    case other
    case unknown
}

/// One row in the synchronized transcript. Both translations come from the same underlying
/// audio segment, so they're always aligned on the same row of the UI.
struct UtterancePair: Identifiable, Equatable {
    let id: String
    var english: String
    var other: String
    var originalLanguage: OriginalLanguage
}
