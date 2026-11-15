import ApelinCore
@testable import ApelinEnvironment
import ApelinGit
@testable import ApelinProtocol
import Foundation
import XCTest

/// An issue opened on a repository the user chose: GitHub's API answered
/// by a fake, the github.com sign-in in memory, Apelin's Info.plist a file
/// under the install root as the package leaves it.
final class GitHubIssueTests: XCTestCase {
    /// GitHub's issues endpoint, noting each request.
    final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        var status = 201
        var message = "Not Found"
        var errors: [[String: String]] = []
        private var log: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { log }
        }

        var exchange: GitHubAPI.Exchange {
            { request in self.answer(request) }
        }

        private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            lock.withLock {
                log.append(request)
                var object: [String: Any] = (200 ..< 300).contains(status)
                    ? ["number": 7, "html_url": "https://github.com/Lakr233/Irisin/issues/7"]
                    : ["message": message]
                if !errors.isEmpty {
                    object["errors"] = errors
                }
                let data = try! JSONSerialization.data(withJSONObject: object)
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private static let token = "gho_issuetoken0123456789abc"

    private func service(_ home: TemporaryHome, github: FakeGitHub, signedIn: Bool = true) throws -> GitHubIssueService {
        let store = MemoryGitCredentialStore()
        if signedIn {
            try store.save(GitCredential(username: "someone", token: Self.token), forHost: "github.com")
        }
        var service = GitHubIssueService(layout: home.layout, credentials: store)
        service.exchange = github.exchange
        service.report.hostName = "Adas-iPhone"
        service.report.osVersion = "17.3.1"
        return service
    }

    private func installApp(_ installRoot: String) throws {
        let app = URL(fileURLWithPath: installRoot).appendingPathComponent("Applications/Apelin.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "23"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
    }

    func testAnIssueGoesToTheRepositoryNamedWithTheFooter() async throws {
        let home = try TemporaryHome(self)
        try installApp(home.layout.installRoot)
        let github = FakeGitHub()
        let request = GitIssueCreateRequest(
            repository: "Lakr233/Irisin",
            title: "  The installer stops at 90% ",
            body: "Installing a package from the inbox stops at 90%.\n",
        )
        let response = try await service(home, github: github).create(request)
        XCTAssertEqual(response, GitIssueCreateResponse(
            number: 7,
            url: "https://github.com/Lakr233/Irisin/issues/7",
            repository: "Lakr233/Irisin",
        ))

        XCTAssertEqual(github.requests.count, 1)
        let sent = try XCTUnwrap(github.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://api.github.com/repos/Lakr233/Irisin/issues", "the repository named, never Apelin's")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["title", "body"], "nothing but the issue")
        XCTAssertEqual(body["title"], "The installer stops at 90%")
        XCTAssertEqual(body["body"], "Installing a package from the inbox stops at 90%.\n\n---\nSent with Apelin 0.3.0 (23) · iOS 17.3.1 · rootless")
    }

    func testGitHubsRefusalsSayWhatBlocksItInItsWords() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        let request = GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "Body")
        let refusals: [(status: Int, message: String, code: ApelinError.Code, words: [String])] = [
            (404, "Not Found", .notFound, ["no repository Lakr233/Irisin", "cannot see it"]),
            (410, "Issues are disabled for this repo", .denied, ["Issues are turned off on Lakr233/Irisin", "Issues are disabled for this repo"]),
            (403, "Repository was archived so is read-only.", .denied, ["does not let the signed-in account", "archived"]),
            (422, "Validation Failed", .conflict, ["refused the issue on Lakr233/Irisin", "Validation Failed", "title is too long"]),
        ]
        for refusal in refusals {
            github.status = refusal.status
            github.message = refusal.message
            github.errors = refusal.status == 422 ? [["message": "title is too long"]] : []
            do {
                _ = try await service(home, github: github).create(request)
                XCTFail("\(refusal.status) went through")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, refusal.code, "\(refusal.status)")
                XCTAssertNil(error.reason)
                for words in refusal.words {
                    XCTAssertTrue(error.message.contains(words), "\(refusal.status): \(error.message)")
                }
                XCTAssertFalse(error.description.contains(Self.token))
            }
        }
        // A revoked sign-in is one to make again.
        github.status = 401
        github.message = "Bad credentials"
        do {
            _ = try await service(home, github: github).create(request)
            XCTFail("a refused sign-in went through")
        } catch let error as ApelinError {
            XCTAssertEqual(error.reason, .authenticationRequired)
        }
        let paths = Set(github.requests.compactMap(\.url?.path))
        XCTAssertEqual(paths, ["/repos/Lakr233/Irisin/issues"], "only the repository named is asked, whatever GitHub answers")
    }

    func testWithoutASignInItSaysSoAndAsksNothingOfGitHub() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        do {
            _ = try await service(home, github: github, signedIn: false)
                .create(GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "Body"))
            XCTFail("sent without a sign-in")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .denied)
            XCTAssertEqual(error.reason, .authenticationRequired)
            XCTAssertTrue(error.message.contains("Settings ▸ Git"), error.message)
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testARefusedRequestReachesNobody() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        // Signed out too: the request is refused before the sign-in is read.
        let service = try service(home, github: github, signedIn: false)
        let refused: [GitIssueCreateRequest] = [
            GitIssueCreateRequest(repository: "Irisin", title: "Title", body: "Body"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin/issues", title: "Title", body: "Body"),
            GitIssueCreateRequest(repository: "-bad/Irisin", title: "Title", body: "Body"),
            GitIssueCreateRequest(repository: "Lakr233/..", title: "Title", body: "Body"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "", body: "Body"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Two\nlines", body: "Body"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: " \n"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "From 192.168.1.20"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "Saved in \(home.home.path)/Projects"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "Built under \(home.layout.installRoot)/usr/lib"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "It is Adas-iPhone that fails"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "UDID 00008030-00112233445566AA"),
            GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "token ghp_" + String(repeating: "A1b2", count: 9)),
        ]
        for request in refused {
            do {
                _ = try await service.create(request)
                XCTFail("sent: \(request.repository) / \(request.title) / \(request.body.prefix(40))")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .badRequest, error.message)
                XCTAssertFalse(error.message.contains("Adas-iPhone") || error.message.contains("192.168"), error.message)
            }
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testTheWorkerServesIt() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        worker.issues = try service(home, github: github)
        let request = GitIssueCreateRequest(repository: "Lakr233/Irisin", title: "Title", body: "Body")
        let (reply, _) = try await worker.handle(ChannelRequest(request: WireRequest(request), descriptors: [], taskID: nil))
        let response = try JSONCoding.decode(GitIssueCreateResponse.self, from: reply.result.get())
        XCTAssertEqual(response.number, 7)
        XCTAssertEqual(github.requests.count, 1)
    }

    func testARepositoryIsNamedAsOwnerAndName() {
        XCTAssertTrue(GitHubName.isFullName("Lakr233/Irisin"))
        XCTAssertTrue(GitHubName.isFullName("owngoal-dev/iOS-SDKs"))
        for name in ["", "Irisin", "/Irisin", "Lakr233/", "a/b/c", "Lakr233/Irisin.git", "under_score/repo", "Lakr233/Iri sin"] {
            XCTAssertFalse(GitHubName.isFullName(name), name)
        }
    }
}
