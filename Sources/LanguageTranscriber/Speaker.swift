import Foundation

/// One row in the synchronized transcript. Both translations come from the same underlying
/// audio segment, so they're always aligned on the same row of the UI.
struct UtterancePair: Identifiable, Equatable {
    let id: String
    var english: String
    var other: String
}
