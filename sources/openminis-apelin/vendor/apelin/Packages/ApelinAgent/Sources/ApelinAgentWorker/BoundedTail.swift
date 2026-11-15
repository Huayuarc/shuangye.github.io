/// The last `limit` bytes of a log, whole lines where it can.
struct BoundedTail {
    let limit: Int
    private(set) var lines: [String] = []
    private var bytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ line: String) {
        lines.append(line)
        bytes += line.utf8.count + 1
        while bytes > limit, lines.count > 1 {
            bytes -= lines.removeFirst().utf8.count + 1
        }
    }

    var text: String {
        lines.joined(separator: "\n")
    }
}
