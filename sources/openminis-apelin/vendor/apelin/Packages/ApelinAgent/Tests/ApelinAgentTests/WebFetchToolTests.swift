@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("apelin_web_fetch")
struct WebFetchToolTests {
    /// Every fetch here goes to `WebStub`, never the network.
    private static let web: WebFetch = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebStub.self]
        return WebFetch(configuration: configuration)
    }()

    private static func fetch(_ url: String, offset: Int? = nil) async throws -> WebPage {
        var arguments: [String: JSONValue] = ["url": .string(url)]
        if let offset {
            arguments["offset"] = .int(offset)
        }
        return try await web.fetch(.object(arguments))
    }

    private static func runner(_ home: TemporaryHome, mode: ApprovalMode, gate: ApprovalGate) throws -> ToolRunner {
        try ToolRunner(
            sessionID: UUID().uuidString,
            project: home.project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: mode),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: gate,
            webFetch: web,
        )
    }

    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined()
    }

    // MARK: Pages

    @Test
    func `an HTML page reads as its text, links absolute`() async throws {
        let host = WebStub.host()
        WebStub.serve("https://\(host)/guide/index.html", .html("""
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <title>Demo &amp; Docs</title>
        <style>body { color: red }</style>
        <script>var x = "<p>not text</p>";</script>
        </head>
        <body>
        <!-- a comment <p>hidden</p> -->
        <noscript>Enable JavaScript</noscript>
        <svg><text>drawn</text></svg>
        <template><p>later</p></template>
        <h1>Getting   started</h1>
        <p>Read the <a href="/docs/intro">intro</a> or <a href="https://other.example/x">another site</a>, not <a href="#top">this</a> or <a href="javascript:void(0)">that</a>.</p>
        <ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
        <p>Fish &lt;&gt; chips&nbsp;&mdash; &#169; &#x1F600; &copy;<br>Next line</p>
        <table><tr><th>Name</th><th>Value</th></tr><tr><td>a</td><td>1</td></tr></table>
        <pre>
        int main() {
            return 0;
        }
        </pre>
        </body></html>
        """))
        let page = try await Self.fetch("https://\(host)/guide/index.html#install")
        #expect(page.url == "https://\(host)/guide/index.html", "the fragment is never sent")
        #expect(page.status == 200 && page.contentType == "text/html" && page.title == "Demo & Docs")
        #expect(page.text == """
        # Getting started

        Read the [intro](https://\(host)/docs/intro) or [another site](https://other.example/x), not this or that.

        - One
        - Two
          - Nested

        Fish <> chips — © 😀 ©
        Next line

        Name | Value
        a | 1

        ```
        int main() {
            return 0;
        }
        ```
        """)
        #expect(page.nextOffset == nil && !page.truncated)
        #expect(page.answer.hasPrefix("https://\(host)/guide/index.html (HTTP 200, text/html)\nTitle: Demo & Docs\n\n# Getting started"))
    }

    @Test
    func `a base, an entity in an href, an empty item and a head left open`() throws {
        let base = try HTMLText("""
        <base href="https://cdn.example.org/root/"><a href="page?a=1&amp;b=2">Page</a> <a href="/x"><img src="logo.png"></a>
        <ul><li></li><li><p>Loose</p></li></ul><h2></h2><p>After</p>
        """, url: #require(URL(string: "https://example.com/")))
        #expect(base.text == "[Page](https://cdn.example.org/root/page?a=1&b=2)\n- Loose\n\nAfter")
        // A head never closed ends where the body's first element begins.
        let open = try HTMLText("<html><head><title>T</title><p>Hello <b>there</b></p>", url: #require(URL(string: "https://example.com/")))
        #expect(open.title == "T" && open.text == "Hello there")
    }

    @Test
    func `the charset is the header's, else the page's meta, else UTF-8`() async throws {
        let host = WebStub.host()
        WebStub.serve("https://\(host)/meta", WebStub.Reply(
            headers: ["Content-Type": "text/html"],
            body: Data("<html><head><meta charset=\"iso-8859-1\"><title>Caf".utf8) + Data([0xE9])
                + Data("</title></head><body><p>Cr".utf8) + Data([0xE8]) + Data("me</p></body></html>".utf8),
        ))
        WebStub.serve("https://\(host)/equiv", WebStub.Reply(
            headers: ["Content-Type": "text/html"],
            body: Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"><p>".utf8)
                + Data([0x93]) + Data("quoted".utf8) + Data([0x94]) + Data("</p>".utf8),
        ))
        WebStub.serve("https://\(host)/header", WebStub.Reply(
            headers: ["Content-Type": "text/plain; charset=ISO-8859-1"],
            body: Data("caf".utf8) + Data([0xE9]),
        ))
        WebStub.serve("https://\(host)/none", WebStub.Reply(
            headers: ["Content-Type": "text/plain"],
            body: Data("caf".utf8) + Data([0xE9]),
        ))
        let meta = try await Self.fetch("https://\(host)/meta")
        #expect(meta.title == "Café" && meta.text == "Crème")
        #expect(try await Self.fetch("https://\(host)/equiv").text == "“quoted”")
        #expect(try await Self.fetch("https://\(host)/header").text == "café")
        #expect(try await Self.fetch("https://\(host)/none").text == "caf\u{FFFD}")
    }

    @Test
    func `long text is answered 32 KB at a time, ending on a line`() async throws {
        let host = WebStub.host()
        let body = (1 ... 4000).map { "\($0): 第\($0)行 text\n" }.joined()
        WebStub.serve("https://\(host)/long.txt", .text(body))
        var pages: [WebPage] = []
        var offset: Int?
        repeat {
            let page = try await Self.fetch("https://\(host)/long.txt", offset: offset)
            #expect(page.text.utf8.count <= WebFetch.pageBytes)
            #expect(page.offset == offset ?? 0)
            pages.append(page)
            offset = page.nextOffset
        } while offset != nil
        #expect(pages.count > 2)
        #expect(pages.map(\.text).joined() == body, "plain text as it is")
        #expect(pages.dropLast().allSatisfy { $0.text.hasSuffix("\n") })
        #expect(pages[0].answer.hasSuffix("… \(pages[0].remainingBytes) more bytes of text; continue with offset \(pages[0].nextOffset ?? 0)"))
        await #expect(throws: ToolArgumentError.self) {
            _ = try await Self.fetch("https://\(host)/long.txt", offset: body.utf8.count + 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a body past 5 MB is cut there and says so`() async throws {
        let host = WebStub.host()
        let line = String(repeating: "a", count: 63) + "\n"
        let body = String(repeating: line, count: WebFetch.maximumBodyBytes / line.utf8.count + 16)
        WebStub.serve("https://\(host)/big.txt", .text(body))
        let page = try await Self.fetch("https://\(host)/big.txt")
        #expect(page.truncated)
        #expect(page.text.utf8.count + page.remainingBytes == WebFetch.maximumBodyBytes)
        #expect(page.answer.hasSuffix("… the page is longer than 5 MB and was cut there"))
    }

    @Test
    func `an error status is answered with its page, not failed`() async throws {
        let host = WebStub.host()
        WebStub.serve("https://\(host)/gone", WebStub.Reply(status: 404, headers: ["Content-Type": "text/html"], body: Data("<h1>Not Found</h1>".utf8)))
        let page = try await Self.fetch("https://\(host)/gone")
        #expect(page.status == 404 && page.text == "# Not Found")
        // A page that script draws says so rather than answering nothing.
        WebStub.serve("https://\(host)/app", .html("<html><body><div id=\"root\"></div><script>render()</script></body></html>"))
        #expect(try await Self.fetch("https://\(host)/app").answer.hasSuffix("\n\n(no text: a page that script draws has none here)"))
    }

    @Test
    func `a type that is not text is refused with its type and size`() async throws {
        let host = WebStub.host()
        WebStub.serve("https://\(host)/logo.png", WebStub.Reply(
            headers: ["Content-Type": "image/png", "Content-Length": "2048"],
            body: Data(repeating: 0x89, count: 2048),
        ))
        WebStub.serve("https://\(host)/blob", WebStub.Reply(headers: [:], body: Data([0x00, 0x01, 0x02])))
        WebStub.serve("https://\(host)/Tweak.m", WebStub.Reply(
            headers: ["Content-Type": "application/octet-stream"],
            body: Data("#import <UIKit/UIKit.h>\n".utf8),
        ))
        let image = await #expect(throws: ToolDeniedError.self) { _ = try await Self.fetch("https://\(host)/logo.png") }
        #expect(image?.message.contains("image/png") == true && image?.message.contains("KB") == true)
        await #expect(throws: ToolDeniedError.self) { _ = try await Self.fetch("https://\(host)/blob") }
        #expect(try await Self.fetch("https://\(host)/Tweak.m").text == "#import <UIKit/UIKit.h>\n")
    }

    // MARK: Where it may go

    @Test
    func `a local, credentialed or non-web address is refused before any request`() throws {
        let refused = [
            "file:///etc/passwd", "ftp://example.com/a", "not a url",
            "https://user:secret@example.com/", "https://user@example.com/",
            "http://localhost:8080/", "http://LOCALHOST./", "http://api.localhost/",
            "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/", "http://0.0.0.0:3000/",
            "http://%31%32%37.0.0.1/", "http://127.0.0.1%2e/", "http://loca%6Chost/",
            "http://10.1.2.3/", "http://172.16.5.4/", "http://192.168.1.1/", "http://100.64.0.1/",
            "http://169.254.169.254/latest/meta-data/", "http://224.0.0.251/", "http://255.255.255.255/",
            "http://[::1]/", "http://[::]/", "http://[fe80::1%25en0]/", "http://[fd00::1]/", "http://[ff02::1]/",
            "http://[::ffff:192.168.0.1]/", "http://[64:ff9b::a00:1]/",
            "http://printer.local/", "http://router/", "http://nas.home.arpa/", "http://db.internal/",
        ]
        for address in refused {
            #expect(throws: ToolArgumentError.self, "\(address)") { _ = try WebFetch.target(address) }
        }
        let allowed = [
            "https://example.com/a", "http://8.8.8.8/", "https://172.32.0.1/", "https://100.128.0.1/",
            "http://[2001:4860:4860::8888]/", "https://github.com:443/owngoal-dev",
        ]
        for address in allowed {
            #expect(try WebFetch.target(address).absoluteString == address, "\(address)")
        }
        #expect(try WebFetch.target(" https://example.com/a#b ").absoluteString == "https://example.com/a")
    }

    @Test
    func `a redirect is checked like the address, and at most five are followed`() async throws {
        let host = WebStub.host()
        WebStub.serve("https://\(host)/admin", WebStub.Reply(status: 302, headers: ["Location": "http://192.168.0.1/admin"]))
        let local = await #expect(throws: ToolDeniedError.self) { _ = try await Self.fetch("https://\(host)/admin") }
        #expect(local?.message.contains("192.168.0.1 is a private network address") == true)
        #expect(!WebStub.requested.contains { $0.contains("192.168.0.1") })

        for hop in 0 ..< 6 {
            WebStub.serve("https://\(host)/hop/\(hop)", WebStub.Reply(status: hop % 2 == 0 ? 302 : 301, headers: ["Location": "/hop/\(hop + 1)"]))
        }
        WebStub.serve("https://\(host)/hop/6", .text("arrived"))
        let five = try await Self.fetch("https://\(host)/hop/1")
        #expect(five.url == "https://\(host)/hop/6" && five.text == "arrived")
        let six = await #expect(throws: ToolDeniedError.self) { _ = try await Self.fetch("https://\(host)/hop/0") }
        #expect(six?.message.contains("more than \(WebFetch.maximumRedirects) times") == true)
    }

    // MARK: Through the runner

    @Test
    func `every chat offers it, and it fetches with no host request`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let host = WebStub.host()
        WebStub.serve("https://\(host)/notes.txt", .text("hello"))
        let events = EventCollector()
        let runner = try Self.runner(home, mode: .relaxed, gate: ApprovalGate { await events.add($0) })
        #expect(runner.agentTools(mcp: []).contains { $0.name == "apelin_web_fetch" })
        #expect(!AgentToolName.webFetch.isProjectOnly, "General Chat has it too")
        let schema = ToolReason.adding(to: AgentToolName.webFetch.parameters)
        #expect(schema["required"] == .array(["url", "reason"]))
        let result = try await runner.run(
            .local(.webFetch),
            toolCallID: "fetch",
            arguments: ["url": .string("https://\(host)/notes.txt"), "offset": ""],
            cancellation: nil,
            mcp: nil,
        )
        #expect(Self.text(result) == "https://\(host)/notes.txt (HTTP 200, text/plain)\n\nhello")
        #expect(await events.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `in Strict mode it asks, and a local address is refused before asking`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let host = WebStub.host()
        WebStub.serve("https://\(host)/page", .text("approved"))
        let gate = ApprovalGate { _ in }
        let runner = try Self.runner(home, mode: .confirm, gate: gate)
        await #expect(throws: ToolArgumentError.self) {
            _ = try await runner.run(.local(.webFetch), toolCallID: "local", arguments: ["url": "http://localhost:3000/"], cancellation: nil, mcp: nil)
        }
        #expect(await gate.pending.isEmpty)

        let task = Task {
            try await runner.run(.local(.webFetch), toolCallID: "page", arguments: ["url": .string("https://\(host)/page")], cancellation: nil, mcp: nil)
        }
        while await gate.pending.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let request = try #require(await gate.pending.first)
        #expect(request.tool == "apelin_web_fetch" && request.allowsSessionScope)
        #expect(request.arguments.contains("https://\(host)/page"))
        #expect(!WebStub.requested.contains("https://\(host)/page"), "nothing is sent before the user answers")
        try await gate.resolve(request.id, decision: .approve(.once))
        #expect(try await Self.text(task.value).hasSuffix("\n\napproved"))
    }
}

/// Answers the requests a test's `WebFetch` sends, by URL, and keeps what
/// was asked for.
final class WebStub: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func html(_ text: String) -> Reply {
            Reply(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(text.utf8))
        }

        static func text(_ text: String) -> Reply {
            Reply(headers: ["Content-Type": "text/plain"], body: Data(text.utf8))
        }
    }

    private final class Book: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: Reply] = [:]
        var requested: [String] = []
    }

    private static let book = Book()

    /// A host of a test's own, so tests running at once never share one.
    static func host() -> String {
        "\(UUID().uuidString.lowercased()).example.test"
    }

    static func serve(_ url: String, _ reply: Reply) {
        book.lock.withLock { book.replies[url] = reply }
    }

    static var requested: [String] {
        book.lock.withLock { book.requested }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.book.lock.withLock {
            Self.book.requested.append(url.absoluteString)
            return Self.book.replies[url.absoluteString]
        } ?? Reply(status: 404)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            return
        }
        // As the network does: the session's delegate is asked about a
        // redirect first, and WebFetch's turns it down.
        if (300 ... 399).contains(reply.status), let location = reply.headers["Location"],
           let next = URL(string: location, relativeTo: url)?.absoluteURL
        {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
