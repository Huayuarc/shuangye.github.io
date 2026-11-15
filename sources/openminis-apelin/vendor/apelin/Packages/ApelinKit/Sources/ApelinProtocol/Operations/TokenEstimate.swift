import Foundation

/// A token count without a tokenizer: about four characters to a token for
/// ASCII text, as for English, code and JSON, and a token to each other
/// character, as for Chinese, Japanese and Korean. The agent counts the
/// output a run is receiving by it until the provider reports its own
/// (`received`), and the conversation page judges how fast a reply streams
/// by it.
public enum TokenEstimate {
    public static func tokens(in text: some StringProtocol) -> Double {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                ascii += 1
            } else {
                other += 1
            }
        }
        return Double(ascii) / 4 + Double(other)
    }
}
