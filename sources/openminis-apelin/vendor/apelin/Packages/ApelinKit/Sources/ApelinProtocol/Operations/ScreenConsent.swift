import Foundation

/// Ask Before Using the Screen (owner, 2026-10-30): a setting of the app's,
/// on by default, under which an agent opens no app or link, reads nothing
/// on the screen and acts on nothing there without the user's approval of
/// that one call, in every approval mode. Asked to report a problem
/// upstream, an agent had opened the issue page in Safari with
/// `icli url open` and read the UI tree twice, never asking.
///
/// The app sends it on every `agentOpen` and `agentPrompt`, as it sends the
/// approval mode; an agent's open takes its opener's. It covers an agent's
/// `readUITree`, its `uiAction` and every `agentRunCode` that runs one of
/// `programs` (`usesScreen`), whatever that one is asked to do: reading
/// through icli reads the screen too. The agent's gate asks on a card each
/// time, never for the session, and the session host lets the call through
/// only by spending one approval the app gave the session whose own
/// `approvalRequested` names exactly it (`detailKey`). Screenshots stay the
/// conversation's rule of 2026-10-29.
public enum ScreenConsent {
    /// The key of an `approvalRequested` `detail` that names a use of the
    /// screen: {operation, request?}, `operation` the host operation it is
    /// for (`readUITree`, `uiAction` or `agentRunCode`) and `request` the
    /// UI tree read or action as the host is asked for it. A command's card
    /// keeps its command under `command`, or `rootCommand` for one that runs
    /// as root, beside it.
    public static let detailKey = "screenControl"

    /// The device's command-line tools that open apps and links or read and
    /// act on the screen: icli, and uikittools' `uiopen` and `uishoot`.
    public static let programs = ["icli", "uiopen", "uishoot"]

    /// What the setting reads as: absent is on, so a caller that never
    /// heard of it cannot turn it off.
    public static func asks(_ setting: Bool?) -> Bool {
        setting != false
    }

    /// Whether `spec` runs one of `programs`: one of its words, or its
    /// script's interpreter or source, names one as a word.
    public static func usesScreen(_ spec: RunCodeSpec) -> Bool {
        switch spec {
        case let .argv(argv): program(inArgv: argv) != nil
        case let .script(interpreter, source): program(inArgv: [interpreter, source]) != nil
        }
    }

    /// The first of `programs` a word of `argv` names: the program itself,
    /// by name or path, or one it runs (`env icli …`, `sh -c "icli …"`).
    public static func program(inArgv argv: [String]) -> String? {
        argv.lazy.compactMap { program(in: $0) }.first
    }

    /// The first of `programs` that `text` names as a word: in any case,
    /// and not inside a longer name of ASCII letters, digits and
    /// underscores, so a path ending in `/icli`, a word of shell text and a
    /// string in a script all count, and `icli-notes` too, while
    /// `musicli` does not. Text that spells one out some other way is not
    /// caught; the prompt asks for consent whatever runs.
    public static func program(in text: String) -> String? {
        let bytes = Array(text.lowercased().utf8)
        return programs.first { contains(Array($0.utf8), asWordIn: bytes) }
    }

    private static func contains(_ word: [UInt8], asWordIn bytes: [UInt8]) -> Bool {
        guard bytes.count >= word.count else { return false }
        for start in 0 ... bytes.count - word.count where bytes[start ..< start + word.count].elementsEqual(word) {
            let end = start + word.count
            let before = start == 0 || !isNameByte(bytes[start - 1])
            let after = end == bytes.count || !isNameByte(bytes[end])
            if before, after {
                return true
            }
        }
        return false
    }

    /// An ASCII letter (lowercased already), digit or underscore.
    private static func isNameByte(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte) || byte == 0x5F
    }
}
