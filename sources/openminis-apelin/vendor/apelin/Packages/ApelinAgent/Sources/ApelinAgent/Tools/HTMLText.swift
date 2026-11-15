import Foundation

/// An HTML page as the text a reader sees, for apelin_web_fetch. What
/// head, script, style, noscript, svg and template elements and comments
/// hold is left out; a block or `br` ends a line, a list item starts with
/// "- ", a heading with its level of "#", a table cell after a row's first
/// with " | ", preformatted text keeps its spacing between ``` lines, and a
/// link reads [text](absolute url). Entities are decoded and the rest of
/// the white space folded. No CSS, script or layout: a page that script
/// draws has little text here.
struct HTMLText {
    private(set) var title: String?
    private(set) var text: String

    init(_ html: String, url: URL) {
        var reader = Reader(bytes: Array(html.utf8), base: url)
        reader.run()
        title = reader.title
        text = reader.output.finished
    }

    /// The charset a page declares in a `<meta>` among its first 4 KB:
    /// `charset="…"`, or the charset of an http-equiv `content`.
    static func declaredCharset(_ html: [UInt8]) -> String? {
        let head = Array(html.prefix(4096))
        let meta = Array("<meta".utf8)
        var index = 0
        while index + meta.count < head.count {
            let start = index
            index += 1
            guard zip(meta, head[start...]).allSatisfy({ $0 == $1 | 0x20 }), isSpace(head[start + meta.count]) else {
                continue
            }
            let end = head[start...].firstIndex(of: Byte.greater) ?? head.count
            let attributes = head[start + meta.count ..< end]
            if let charset = attribute("charset", in: attributes)?.trimmingCharacters(in: .whitespaces), !charset.isEmpty {
                return charset
            }
            if let content = attribute("content", in: attributes), let charset = WebFetch.charset(content) {
                return charset
            }
        }
        return nil
    }

    /// The value of the attribute `name` among a tag's attribute bytes,
    /// entities decoded; "" for one with no value.
    static func attribute(_ name: String, in tag: ArraySlice<UInt8>) -> String? {
        var index = tag.startIndex
        while index < tag.endIndex {
            let start = index
            while index < tag.endIndex, isSpace(tag[index]) || tag[index] == Byte.slash {
                index += 1
            }
            let nameStart = index
            while index < tag.endIndex, !isSpace(tag[index]), tag[index] != Byte.equals, tag[index] != Byte.slash {
                index += 1
            }
            let attribute = String(decoding: tag[nameStart ..< index], as: UTF8.self).lowercased()
            while index < tag.endIndex, isSpace(tag[index]) {
                index += 1
            }
            var value: ArraySlice<UInt8> = []
            if index < tag.endIndex, tag[index] == Byte.equals {
                index += 1
                while index < tag.endIndex, isSpace(tag[index]) {
                    index += 1
                }
                if index < tag.endIndex, tag[index] == Byte.quote || tag[index] == Byte.apostrophe {
                    let valueStart = index + 1
                    index = tag[valueStart...].firstIndex(of: tag[index]) ?? tag.endIndex
                    value = tag[valueStart ..< index]
                    index = min(index + 1, tag.endIndex)
                } else {
                    let valueStart = index
                    while index < tag.endIndex, !isSpace(tag[index]) {
                        index += 1
                    }
                    value = tag[valueStart ..< index]
                }
            }
            if attribute == name {
                return decoded(value)
            }
            if index == start {
                index += 1
            }
        }
        return nil
    }

    /// Entities decoded, nothing folded.
    private static func decoded(_ bytes: ArraySlice<UInt8>) -> String {
        var output: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == Byte.ampersand, let (scalar, next) = HTMLEntity.decode(bytes, at: index) {
                Unicode.UTF8.encode(scalar) { output.append($0) }
                index = next
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "_")
    }
}

private enum Byte {
    static let less = UInt8(ascii: "<")
    static let greater = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let equals = UInt8(ascii: "=")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let ampersand = UInt8(ascii: "&")
    static let space = UInt8(ascii: " ")
    static let newline = UInt8(ascii: "\n")
}

/// Walks the page's bytes once: text is written as it comes, and a tag
/// changes how what follows is written.
private struct Reader {
    let bytes: [UInt8]
    var base: URL
    var title: String?
    var output = TextWriter()
    private var hasBase = false
    private var inHead = false
    /// The link whose text is being written: where it starts, and where it goes.
    private var link: (start: Int, url: String)?

    init(bytes: [UInt8], base: URL) {
        self.bytes = bytes
        self.base = base
    }

    /// The elements whose content is never text a reader sees.
    private static let hidden: Set = ["script", "style", "noscript", "svg", "template"]
    /// What a head holds; any other element ends it, as a browser's parser
    /// ends a head left open.
    private static let headElements: Set = [
        "html", "head", "title", "meta", "link", "base", "script", "style", "noscript", "template",
    ]
    private static let blocks: Set = [
        "address", "article", "aside", "blockquote", "caption", "dd", "details", "dialog", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "header", "hgroup", "hr", "main", "nav", "p",
        "section", "summary", "table", "tbody", "tfoot", "thead", "tr",
    ]
    /// Blocks set off by an empty line.
    private static let paragraphs: Set = ["blockquote", "figure", "hr", "p", "table"]
    private static let headings = ["h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6]

    private static let commentStart = Array("<!--".utf8)
    private static let commentEnd = Array("-->".utf8)
    private static let dataStart = Array("<![CDATA[".utf8)
    private static let dataEnd = Array("]]>".utf8)
    private static let tagEnd = [Byte.greater]

    mutating func run() {
        var index = 0
        var textStart = 0
        while index < bytes.count {
            guard bytes[index] == Byte.less, index + 1 < bytes.count, startsMarkup(bytes[index + 1]) else {
                index += 1
                continue
            }
            writeText(textStart ..< index)
            index = markup(at: index)
            textStart = index
        }
        writeText(textStart ..< bytes.count)
        closeLink()
    }

    /// `<` begins markup before a letter, `/`, `!` or `?`; otherwise it is text.
    private func startsMarkup(_ byte: UInt8) -> Bool {
        byte == Byte.slash || byte == Byte.bang || byte == Byte.question || HTMLText.isLetter(byte)
    }

    private mutating func writeText(_ range: Range<Int>) {
        if !inHead, !range.isEmpty {
            output.write(bytes[range])
        }
    }

    /// Reads the comment, declaration or tag at `start` and answers the
    /// index after it.
    private mutating func markup(at start: Int) -> Int {
        let next = bytes[start + 1]
        if next == Byte.bang {
            if matches(Self.commentStart, at: start) {
                return after(Self.commentEnd, from: start + Self.commentStart.count)
            }
            if matches(Self.dataStart, at: start) {
                return after(Self.dataEnd, from: start + Self.dataStart.count)
            }
            return after(Self.tagEnd, from: start + 2)
        }
        if next == Byte.question {
            return after(Self.tagEnd, from: start + 2)
        }
        let closing = next == Byte.slash
        let nameStart = closing ? start + 2 : start + 1
        var nameEnd = nameStart
        while nameEnd < bytes.count, HTMLText.isNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }
        let tagEnd = endOfTag(from: nameEnd)
        let end = min(tagEnd + 1, bytes.count)
        guard nameEnd > nameStart else { return end }
        let name = String(decoding: bytes[nameStart ..< nameEnd], as: UTF8.self).lowercased()
        if closing {
            close(name)
            return end
        }
        let selfClosing = tagEnd > nameEnd && tagEnd < bytes.count && bytes[tagEnd - 1] == Byte.slash
        return open(name, attributes: bytes[nameEnd ..< tagEnd], selfClosing: selfClosing, end: end)
    }

    private mutating func open(_ name: String, attributes: ArraySlice<UInt8>, selfClosing: Bool, end: Int) -> Int {
        if inHead, !Self.headElements.contains(name) {
            inHead = false
        }
        if Self.hidden.contains(name) || name == "title" {
            guard !selfClosing else { return end }
            let (contentEnd, after) = closingTag(name, from: end)
            if name == "title", title == nil {
                var writer = TextWriter()
                writer.write(bytes[end ..< contentEnd])
                title = writer.finished
            }
            return after
        }
        if let level = Self.headings[name] {
            output.heading(level)
            return end
        }
        switch name {
        case "head":
            inHead = true
        case "base":
            if !hasBase, let href = HTMLText.attribute("href", in: attributes),
               let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL
            {
                base = url
                hasBase = true
            }
        case "a":
            closeLink()
            if let href = HTMLText.attribute("href", in: attributes), let url = resolve(href) {
                link = (output.count, url)
            }
        case "br":
            output.lineBreak()
        case "li":
            output.listItem()
        case "ul", "ol":
            output.startList()
        case "pre":
            output.startPreformatted()
        case "td", "th":
            output.cell()
        default:
            if Self.blocks.contains(name) {
                output.breakLine(blank: Self.paragraphs.contains(name))
            }
        }
        return end
    }

    private mutating func close(_ name: String) {
        if Self.headings[name] != nil {
            output.endMarked(blank: true)
            return
        }
        switch name {
        case "head":
            inHead = false
        case "a":
            closeLink()
        case "li":
            output.endMarked(blank: false)
        case "ul", "ol":
            output.endList()
        case "pre":
            output.endPreformatted()
        default:
            if Self.blocks.contains(name) {
                output.breakLine(blank: Self.paragraphs.contains(name))
            }
        }
    }

    private mutating func closeLink() {
        guard let open = link else { return }
        link = nil
        output.link(from: open.start, to: open.url)
    }

    /// An http or https link, absolute; nil for a place on this page, a
    /// script or any other scheme, whose text stays plain.
    private func resolve(_ href: String) -> String? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.hasPrefix("#"),
              let url = URL(string: href, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    private func matches(_ literal: [UInt8], at index: Int) -> Bool {
        index + literal.count <= bytes.count && bytes[index ..< index + literal.count].elementsEqual(literal)
    }

    /// The index after the first `terminator` from `start`, or the end.
    private func after(_ terminator: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if bytes[index] == terminator[0], matches(terminator, at: index) {
                return index + terminator.count
            }
            index += 1
        }
        return bytes.count
    }

    /// The `>` ending a tag, past any quoted attribute value; the end when
    /// there is none.
    private func endOfTag(from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case Byte.greater:
                return index
            case Byte.equals:
                index += 1
                while index < bytes.count, HTMLText.isSpace(bytes[index]) {
                    index += 1
                }
                if index < bytes.count, bytes[index] == Byte.quote || bytes[index] == Byte.apostrophe {
                    index = (bytes[(index + 1)...].firstIndex(of: bytes[index]) ?? bytes.count) + 1
                }
            default:
                index += 1
            }
        }
        return bytes.count
    }

    /// Where an element's raw content ends, at its `</name>`, and the
    /// index after that tag; the end of the page when it is never closed.
    private func closingTag(_ name: String, from start: Int) -> (contentEnd: Int, after: Int) {
        let name = Array(name.utf8)
        var index = start
        while index + 2 + name.count <= bytes.count {
            if bytes[index] == Byte.less, bytes[index + 1] == Byte.slash,
               zip(name, bytes[(index + 2)...]).allSatisfy({ $0 == $1 | 0x20 })
            {
                let afterName = index + 2 + name.count
                if afterName == bytes.count || !HTMLText.isNameByte(bytes[afterName]) {
                    return (index, min(endOfTag(from: afterName) + 1, bytes.count))
                }
            }
            index += 1
        }
        return (bytes.count, bytes.count)
    }
}

/// The text as it is written: white space folded outside `pre`, one empty
/// line at most between blocks.
private struct TextWriter {
    private var bytes: [UInt8] = []
    private var pendingSpace = false
    private var preformatted = 0
    /// A newline straight after `<pre>` is not the text's.
    private var atPreformattedStart = false
    private var lists = 0
    /// Where a list item's or heading's marker begins, until text follows it.
    private var marker: Int?

    var count: Int {
        bytes.count
    }

    var finished: String {
        var bytes = bytes
        if let marker {
            bytes.removeSubrange(marker...)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func write(_ text: ArraySlice<UInt8>) {
        var index = text.startIndex
        while index < text.endIndex {
            let byte = text[index]
            if byte == Byte.ampersand, let (scalar, next) = HTMLEntity.decode(text, at: index) {
                if scalar == "\u{A0}" {
                    space(Byte.space)
                } else {
                    flushSpace()
                    Unicode.UTF8.encode(scalar) { bytes.append($0) }
                }
                index = next
            } else if byte == 0xC2, index + 1 < text.endIndex, text[index + 1] == 0xA0 {
                // A no-break space, U+00A0, folds as any other.
                space(Byte.space)
                index += 2
            } else if HTMLText.isSpace(byte) {
                space(byte)
                index += 1
            } else {
                flushSpace()
                bytes.append(byte)
                index += 1
            }
        }
    }

    private mutating func space(_ byte: UInt8) {
        guard preformatted > 0 else {
            pendingSpace = true
            return
        }
        if byte == 0x0D {
            return
        }
        defer { atPreformattedStart = false }
        if byte == Byte.newline, atPreformattedStart {
            return
        }
        bytes.append(byte == 0x0C ? Byte.space : byte)
    }

    /// Before text: the space folded from what came before it, unless the
    /// line has just begun.
    private mutating func flushSpace() {
        marker = nil
        atPreformattedStart = false
        guard pendingSpace else { return }
        pendingSpace = false
        if let last = bytes.last, last != Byte.newline, last != Byte.space {
            bytes.append(Byte.space)
        }
    }

    private mutating func trimSpaces() {
        while bytes.last == Byte.space {
            bytes.removeLast()
        }
    }

    private var endsWithEmptyLine: Bool {
        bytes.count >= 2 && bytes[bytes.count - 1] == Byte.newline && bytes[bytes.count - 2] == Byte.newline
    }

    /// Ends the line, and with `blank` leaves an empty one after it; a
    /// marker still waiting for its text keeps its line.
    mutating func breakLine(blank: Bool = false) {
        pendingSpace = false
        guard marker == nil, !bytes.isEmpty else { return }
        if preformatted == 0 {
            trimSpaces()
        }
        if bytes.last != Byte.newline {
            bytes.append(Byte.newline)
        }
        if blank, !endsWithEmptyLine {
            bytes.append(Byte.newline)
        }
    }

    /// `<br>`: a new line even at a line's start, up to one empty line.
    mutating func lineBreak() {
        if preformatted > 0 {
            bytes.append(Byte.newline)
            return
        }
        pendingSpace = false
        guard marker == nil else { return }
        trimSpaces()
        if !bytes.isEmpty, !endsWithEmptyLine {
            bytes.append(Byte.newline)
        }
    }

    mutating func heading(_ level: Int) {
        dropMarker()
        breakLine(blank: true)
        startMarker(String(repeating: "#", count: level) + " ")
    }

    mutating func startList() {
        breakLine()
        lists += 1
    }

    mutating func endList() {
        lists = max(0, lists - 1)
        endMarked(blank: false)
    }

    mutating func listItem() {
        dropMarker()
        breakLine()
        startMarker(String(repeating: "  ", count: max(0, lists - 1)) + "- ")
    }

    /// The end of a list item or heading; one with no text leaves nothing.
    mutating func endMarked(blank: Bool) {
        dropMarker()
        breakLine(blank: blank)
    }

    /// A table cell after the row's first.
    mutating func cell() {
        guard marker == nil else { return }
        pendingSpace = false
        trimSpaces()
        if let last = bytes.last, last != Byte.newline {
            bytes.append(contentsOf: " | ".utf8)
        }
    }

    mutating func startPreformatted() {
        preformatted += 1
        guard preformatted == 1 else { return }
        dropMarker()
        breakLine(blank: true)
        bytes.append(contentsOf: "```\n".utf8)
        atPreformattedStart = true
    }

    mutating func endPreformatted() {
        guard preformatted > 0 else { return }
        preformatted -= 1
        guard preformatted == 0 else { return }
        if bytes.last != Byte.newline {
            bytes.append(Byte.newline)
        }
        bytes.append(contentsOf: "```".utf8)
        breakLine(blank: true)
    }

    /// Makes the text written since `start` a link, on one line, the space
    /// before it kept outside; a link with no text stays as it was.
    mutating func link(from start: Int, to url: String) {
        guard start <= bytes.count else { return }
        var labelStart = start
        while labelStart < bytes.count, bytes[labelStart] == Byte.space || bytes[labelStart] == Byte.newline {
            labelStart += 1
        }
        var label = Array(bytes[labelStart...])
        while let last = label.last, last == Byte.space || last == Byte.newline {
            label.removeLast()
        }
        guard !label.isEmpty else { return }
        label = label.map { $0 == Byte.newline ? Byte.space : $0 }
        bytes.replaceSubrange(labelStart..., with: [UInt8(ascii: "[")] + label + Array("](\(url))".utf8))
    }

    private mutating func startMarker(_ text: String) {
        marker = bytes.count
        bytes.append(contentsOf: text.utf8)
    }

    /// A marker no text followed: an empty list item or heading.
    private mutating func dropMarker() {
        guard let start = marker else { return }
        bytes.removeSubrange(start...)
        marker = nil
    }
}

/// The character references a page spells most: `&#…;` and `&#x…;` for
/// any character, and the named ones below. Any other stays as written.
private enum HTMLEntity {
    static func decode(_ bytes: ArraySlice<UInt8>, at start: Int) -> (Unicode.Scalar, Int)? {
        var index = start + 1
        guard index < bytes.endIndex else { return nil }
        if bytes[index] == UInt8(ascii: "#") {
            index += 1
            let hex = index < bytes.endIndex && bytes[index] | 0x20 == UInt8(ascii: "x")
            if hex {
                index += 1
            }
            let digits = index
            while index < bytes.endIndex, index - digits < 8, hex ? isHexDigit(bytes[index]) : HTMLText.isDigit(bytes[index]) {
                index += 1
            }
            guard index > digits, index < bytes.endIndex, bytes[index] == UInt8(ascii: ";"),
                  let value = UInt32(String(decoding: bytes[digits ..< index], as: UTF8.self), radix: hex ? 16 : 10)
            else { return nil }
            let scalar = value == 0 ? nil : Unicode.Scalar(value)
            return (scalar ?? "\u{FFFD}", index + 1)
        }
        let name = index
        while index < bytes.endIndex, index - name < 10, HTMLText.isLetter(bytes[index]) || HTMLText.isDigit(bytes[index]) {
            index += 1
        }
        guard index > name, index < bytes.endIndex, bytes[index] == UInt8(ascii: ";"),
              let scalar = named[String(decoding: bytes[name ..< index], as: UTF8.self)] else { return nil }
        return (scalar, index + 1)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        HTMLText.isDigit(byte) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x66)
    }

    private static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "shy": "\u{AD}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "middot": "·", "bull": "•",
        "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "micro": "µ", "para": "¶", "sect": "§",
        "cent": "¢", "pound": "£", "euro": "€", "yen": "¥",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒",
        "le": "≤", "ge": "≥", "ne": "≠", "infin": "∞", "check": "✓",
    ]
}
