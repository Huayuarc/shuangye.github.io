// TreeSitterLanguages' JSON highlights, kept as literals so
// the package ships no resource bundle for them.

extension RunestoneQueries {
    static let jsonHighlights = ##"""
(pair
  key: (_) @string.special.key)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @escape

(comment) @comment
"""##
}
