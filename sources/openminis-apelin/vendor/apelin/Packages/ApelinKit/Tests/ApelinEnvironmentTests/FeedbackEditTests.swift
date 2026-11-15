import ApelinCore
@testable import ApelinEnvironment
import ApelinGit
@testable import ApelinProtocol
import Foundation
import XCTest

/// An issue feedback filed, read and edited on Apelin's own repository:
/// GitHub's API answered by a fake that keeps the issues and applies an
/// edit, the github.com sign-in in memory.
final class FeedbackEditTests: XCTestCase {
    /// `/user`, and the issues of owngoal-dev/Apelin by number, noting each
    /// request.
    final class IssueGitHub: @unchecked Sendable {
        struct Issue {
            var title: String
            var body: String?
            var author: String = "someone"
            var state = "open"
            var isPullRequest = false
            /// Where GitHub says it is, when it moved it.
            var htmlURL: String?
        }

        private let lock = NSLock()
        var login = "Someone"
        var issues: [Int: Issue] = [:]
        private var log: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { log }
        }

        var edits: [[String: String]] {
            requests.filter { $0.httpMethod == "PATCH" }.compactMap { request in
                request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            }
        }

        var exchange: GitHubAPI.Exchange {
            { request in self.answer(request) }
        }

        func issue(_ number: Int) -> Issue? {
            lock.withLock { issues[number] }
        }

        func set(_ number: Int, _ issue: Issue) {
            lock.withLock { issues[number] = issue }
        }

        private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            lock.withLock {
                log.append(request)
                let path = request.url?.path ?? ""
                let prefix = "/repos/owngoal-dev/Apelin/issues/"
                var status = 200
                var object: [String: Any] = ["message": "Not Found"]
                if path == "/user" {
                    object = ["login": login]
                } else if path.hasPrefix(prefix), let number = Int(path.dropFirst(prefix.count)), var issue = issues[number] {
                    if request.httpMethod == "PATCH",
                       let fields = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
                    {
                        issue.title = fields["title"] ?? issue.title
                        issue.body = fields["body"] ?? issue.body
                        issues[number] = issue
                    }
                    object = [
                        "number": number,
                        "html_url": issue.htmlURL ?? "https://github.com/owngoal-dev/Apelin/\(issue.isPullRequest ? "pull" : "issues")/\(number)",
                        "title": issue.title,
                        "body": issue.body.map { $0 as Any } ?? NSNull(),
                        "state": issue.state,
                        "user": ["login": issue.author],
                    ]
                    if issue.isPullRequest {
                        object["pull_request"] = ["url": "https://api.github.com/repos/owngoal-dev/Apelin/pulls/\(number)"]
                    }
                } else {
                    status = 404
                }
                let data = try! JSONSerialization.data(withJSONObject: object)
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private static let token = "gho_feedbacktoken0123456789"
    /// The footer an earlier Apelin wrote, which an edit keeps as it is.
    private static let footer = "Sent with Apelin 0.2.7 (18) · iOS 17.3.1 · rootless"

    private func service(_ home: TemporaryHome, github: IssueGitHub, signedIn: Bool = true) throws -> FeedbackService {
        let store = MemoryGitCredentialStore()
        if signedIn {
            try store.save(GitCredential(username: "someone", token: Self.token), forHost: "github.com")
        }
        var service = FeedbackService(layout: home.layout, credentials: store)
        service.exchange = github.exchange
        service.report.hostName = "Adas-iPhone"
        service.report.osVersion = "26.0"
        return service
    }

    private func filed(_ github: IssueGitHub, number: Int = 12, author: String = "someone") {
        github.set(number, IssueGitHub.Issue(
            title: "The build log stops early",
            body: FeedbackRules.issueBody("It ends before the link step.", footer: Self.footer),
            author: author,
        ))
    }

    private func edit(title: String? = nil, body: String? = nil, number: Int = 12) -> FeedbackEditRequest {
        FeedbackEditRequest(
            number: number,
            title: title,
            body: body,
            expectedTitle: "The build log stops early",
            expectedBody: "It ends before the link step.",
        )
    }

    // MARK: Reading

    func testAReadSplitsTheFooterOffAndSaysWhetherTheAccountOpenedIt() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        filed(github)
        let read = try await service(home, github: github).read(FeedbackReadRequest(number: 12))
        XCTAssertEqual(read, FeedbackReadResponse(
            number: 12,
            url: "https://github.com/owngoal-dev/Apelin/issues/12",
            title: "The build log stops early",
            body: "It ends before the link step.",
            footer: Self.footer,
            author: "someone",
            state: "open",
            isAuthor: true,
        ), "the login is compared without case")
        for sent in github.requests {
            XCTAssertEqual(sent.httpMethod, "GET")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token)")
        }
        XCTAssertEqual(
            Set(github.requests.compactMap(\.url?.absoluteString)),
            ["https://api.github.com/repos/owngoal-dev/Apelin/issues/12", "https://api.github.com/user"],
        )

        // Another account's issue, and one whose footer and body are gone.
        github.set(13, IssueGitHub.Issue(title: "Crash on launch", body: nil, author: "other", state: "closed"))
        let theirs = try await service(home, github: github).read(FeedbackReadRequest(number: 13))
        XCTAssertFalse(theirs.isAuthor)
        XCTAssertEqual(theirs.author, "other")
        XCTAssertEqual(theirs.body, "")
        XCTAssertNil(theirs.footer)
        XCTAssertEqual(theirs.state, "closed")
    }

    func testOnlyAnIssueOfApelinsRepositoryIsRead() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        github.set(5, IssueGitHub.Issue(title: "Fix the build", body: "Diff", isPullRequest: true))
        github.set(6, IssueGitHub.Issue(
            title: "Moved",
            body: "Body",
            htmlURL: "https://github.com/someone/elsewhere/issues/1",
        ))
        let service = try service(home, github: github)
        let refused: [(number: Int, words: String)] = [(5, "pull request"), (6, "no longer an issue"), (7, "has no issue #7")]
        for (number, words) in refused {
            do {
                _ = try await service.read(FeedbackReadRequest(number: number))
                XCTFail("#\(number) was read")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .notFound)
                XCTAssertTrue(error.message.contains(words), error.message)
            }
            do {
                _ = try await service.edit(edit(body: "New", number: number))
                XCTFail("#\(number) was edited")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .notFound)
            }
        }
        XCTAssertTrue(github.edits.isEmpty)
        for sent in github.requests where sent.url?.path != "/user" {
            XCTAssertTrue(sent.url?.path.hasPrefix("/repos/owngoal-dev/Apelin/issues/") == true, "\(sent.url?.path ?? "")")
        }
    }

    // MARK: Editing

    func testAnEditSendsOnlyWhatChangesAndKeepsTheFooterAsItWas() async throws {
        let home = try TemporaryHome(self)
        // This device runs a later Apelin: the footer stays the one written.
        let app = URL(fileURLWithPath: home.layout.installRoot).appendingPathComponent("Applications/Apelin.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "23"],
            format: .binary,
            options: 0,
        ).write(to: app.appendingPathComponent("Info.plist"))
        let github = IssueGitHub()
        filed(github)
        let service = try service(home, github: github)

        let broadened = try await service.edit(edit(body: "It ends before the link step, on roothide and rootless.\n"))
        XCTAssertEqual(broadened, FeedbackEditResponse(
            number: 12,
            url: "https://github.com/owngoal-dev/Apelin/issues/12",
            title: "The build log stops early",
            body: "It ends before the link step, on roothide and rootless.",
        ))
        XCTAssertEqual(github.edits, [["body": "It ends before the link step, on roothide and rootless.\n\n---\n" + Self.footer]])
        let patch = try XCTUnwrap(github.requests.last)
        XCTAssertEqual(patch.url?.absoluteString, "https://api.github.com/repos/owngoal-dev/Apelin/issues/12")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token)")

        // A title alone, sent alone; a body the request repeats is no change.
        let retitled = try await service.edit(FeedbackEditRequest(
            number: 12,
            title: "  The build log stops before linking ",
            body: "It ends before the link step, on roothide and rootless.",
            expectedTitle: "The build log stops early",
            expectedBody: "It ends before the link step, on roothide and rootless.",
        ))
        XCTAssertEqual(retitled.title, "The build log stops before linking")
        XCTAssertEqual(github.edits.last, ["title": "The build log stops before linking"])
        XCTAssertEqual(github.issue(12)?.body, "It ends before the link step, on roothide and rootless.\n\n---\n" + Self.footer)
    }

    func testAnEditMadeMeanwhileOnGitHubIsNeverOverwritten() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        filed(github)
        // The user added a line on the site, after the edit was read.
        let theirs = "It ends before the link step.\r\nAlso on iOS 26.\r\n\r\n---\r\n" + Self.footer
        github.set(12, IssueGitHub.Issue(title: "The build log stops early", body: theirs))
        let service = try service(home, github: github)
        do {
            _ = try await service.edit(edit(body: "Broadened."))
            XCTFail("an edit made against an older text went through")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertTrue(error.message.contains("read it again"), error.message)
        }
        XCTAssertTrue(github.edits.isEmpty, "nothing is written")
        XCTAssertEqual(github.issue(12)?.body, theirs)

        // Made against what it says now, with GitHub's line ends, it goes
        // through, and the footer keeps them.
        let read = try await service.read(FeedbackReadRequest(number: 12))
        XCTAssertEqual(read.body, "It ends before the link step.\r\nAlso on iOS 26.")
        _ = try await service.edit(FeedbackEditRequest(
            number: 12, title: nil, body: read.body + "\r\nAnd on 17.",
            expectedTitle: read.title, expectedBody: read.body,
        ))
        XCTAssertEqual(github.edits, [["body": read.body + "\r\nAnd on 17.\r\n\r\n---\r\n" + Self.footer]])

        // A title changed meanwhile holds the edit up too.
        var retitled = try XCTUnwrap(github.issue(12))
        retitled.title = "Renamed on GitHub"
        github.set(12, retitled)
        do {
            _ = try await service.edit(FeedbackEditRequest(
                number: 12, title: "Mine", body: nil, expectedTitle: read.title, expectedBody: read.body + "\r\nAnd on 17.",
            ))
            XCTFail("an edit made against an older title went through")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .conflict)
        }
        XCTAssertEqual(github.edits.count, 1)
    }

    func testOnlyAnIssueTheAccountOpenedIsEdited() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        filed(github, author: "other")
        do {
            _ = try await service(home, github: github).edit(edit(body: "Broadened."))
            XCTFail("another account's issue was edited")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .denied)
            XCTAssertTrue(error.message.contains("other"), error.message)
        }
        XCTAssertTrue(github.edits.isEmpty)
    }

    func testTheNewTextIsCheckedBeforeTheSignInIsRead() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        filed(github)
        // Signed out: a refused edit reaches nobody.
        let service = try service(home, github: github, signedIn: false)
        let refused: [FeedbackEditRequest] = [
            edit(title: "", body: nil),
            edit(title: "Two\nlines"),
            edit(body: " \n"),
            edit(body: "From 192.168.1.20"),
            edit(body: "Saved in \(home.home.path)/Projects"),
            edit(body: "It is Adas-iPhone that fails"),
            edit(body: "token ghp_" + String(repeating: "A1b2", count: 9)),
            edit(body: FeedbackRules.issueBody("Body", footer: Self.footer)),
            edit(),
            edit(title: "  The build log stops early ", body: "It ends before the link step."),
            edit(body: "New", number: 0),
        ]
        for request in refused {
            do {
                _ = try await service.edit(request)
                XCTFail("edited: \(request.title ?? "-") / \(request.body ?? "-")")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .badRequest, error.message)
                XCTAssertFalse(error.message.contains("Adas-iPhone") || error.message.contains("192.168"), error.message)
            }
        }
        do {
            _ = try await service.read(FeedbackReadRequest(number: 0))
            XCTFail("issue 0 was read")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testWithoutASignInItSaysSoAndAsksNothingOfGitHub() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        filed(github)
        let signedOut = try service(home, github: github, signedIn: false)
        for call in [
            { _ = try await signedOut.read(FeedbackReadRequest(number: 12)) },
            { _ = try await signedOut.edit(self.edit(body: "Broadened.")) },
        ] as [() async throws -> Void] {
            do {
                try await call()
                XCTFail("GitHub was asked without a sign-in")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .denied)
                XCTAssertEqual(error.reason, .authenticationRequired)
                XCTAssertTrue(error.message.contains("Settings ▸ Git"), error.message)
            }
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testTheWorkerServesBoth() async throws {
        let home = try TemporaryHome(self)
        let github = IssueGitHub()
        filed(github)
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        worker.feedback = try service(home, github: github)
        let (read, _) = try await worker.handle(ChannelRequest(request: WireRequest(FeedbackReadRequest(number: 12)), descriptors: [], taskID: nil))
        XCTAssertEqual(try JSONCoding.decode(FeedbackReadResponse.self, from: read.result.get()).footer, Self.footer)
        let (edited, _) = try await worker.handle(ChannelRequest(request: WireRequest(edit(body: "Broadened.")), descriptors: [], taskID: nil))
        XCTAssertEqual(try JSONCoding.decode(FeedbackEditResponse.self, from: edited.result.get()).body, "Broadened.")
        XCTAssertEqual(github.edits.count, 1)
    }
}
