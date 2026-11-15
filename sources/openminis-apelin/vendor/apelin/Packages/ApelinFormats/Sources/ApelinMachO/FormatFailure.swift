// Copied from Fila (MIT, OwnGoal Studio): FilaFormats/FormatFailure.swift,
// with the cases only Fila's archive and plist readers throw dropped.

import Foundation

/// Everything the Mach-O reader can fail with.
///
/// The messages are for logs and diagnostics, not for the screen: a caller
/// that shows the user a sentence maps the case to its own localized text.
public enum FormatFailure: Error, Sendable, Hashable {
    /// The magic is not Mach-O. Not a corruption: it is the answer to "is this
    /// a binary", and callers use it to fall through to the next reader.
    case notRecognised

    /// Structurally broken, with where. Mach-O headers are attacker-controlled
    /// input — every length in them is checked against the bytes actually
    /// present, and this is what a failed check throws rather than reading
    /// whatever happens to come next.
    case damaged(String)

    /// Refused before allocating. Reaching for `Data(count:)` with a number
    /// that came out of a file is how a viewer for a 4 GB file becomes a 4 GB
    /// allocation.
    case tooLarge(byteCount: Int64, limit: Int64)

    /// A syscall failed and left this `errno`.
    case system(errno: Int32)
}
