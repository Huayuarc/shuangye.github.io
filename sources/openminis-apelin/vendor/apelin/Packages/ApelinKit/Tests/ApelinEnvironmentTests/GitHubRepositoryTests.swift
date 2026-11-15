import ApelinCore
@testable import ApelinEnvironment
import ApelinGit
@testable import ApelinProtocol
import Foundation
import XCTest

/// An empty repository made on GitHub for a project to push to: GitHub's
/// API answered by a fake, the github.com sign-in in memory.
final class GitHubRepositoryTests: XCTestCase {
    /// GitHub's account and repository-making endpoints, noting each request.
    final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        var login = "someone"
        /// `owner/name` GitHub has already.
        var taken: Set<String> = []
        /// The organizations the account belongs to, and whether it may
        /// make repositories in each.
        var organizations: [String: Bool] = [:]
        private var log: [(method: String, path: String, body: [String: Any]?)] = []

        var requests: [(method: String, path: String, body: [String: Any]?)] {
            lock.withLock { log }
        }

        var exchange: GitHubAPI.Exchange {
            { request in self.answer(request) }
        }

        private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            let path = request.url!.path
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return lock.withLock {
                log.append((method, path, body))
                func reply(_ status: Int, _ object: [String: Any]) -> (Data, HTTPURLResponse) {
                    let data = try! JSONSerialization.data(withJSONObject: object)
                    return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                if method == "GET", path == "/user" {
                    return reply(200, ["login": login])
                }
                let parts = path.split(separator: "/").map(String.init)
                let owner: String
                switch (method, parts.count) {
                case ("POST", 2) where parts == ["user", "repos"]:
                    owner = login
                case ("POST", 3) where parts[0] == "orgs" && parts[2] == "repos":
                    owner = parts[1]
                    guard let mayCreate = organizations[owner] else { return reply(404, ["message": "Not Found"]) }
                    guard mayCreate else {
                        return reply(403, ["message": "You need admin access to the organization before adding a repository to it."])
                    }
                default:
                    return reply(404, ["message": "Not Found"])
                }
                let name = body?["name"] as? String ?? ""
                guard taken.insert("\(owner)/\(name)").inserted else {
                    return reply(422, [
                        "message": "Repository creation failed.",
                        "errors": [["resource": "Repository", "field": "name", "message": "name already exists on this account"]],
                    ])
                }
                return reply(201, [
                    "name": name, "full_name": "\(owner)/\(name)", "owner": ["login": owner],
                    "private": body?["private"] as? Bool ?? false, "description": body?["description"] ?? NSNull(),
                    "html_url": "https://github.com/\(owner)/\(name)", "clone_url": "https://github.com/\(owner)/\(name).git",
                    "default_branch": "main", "permissions": ["push": true],
                ])
            }
        }
    }

    private static let token = "gho_repositorytoken0123456789"

    private func service(github: FakeGitHub, signedIn: Bool = true) throws -> GitHubRepositoryService {
        let store = MemoryGitCredentialStore()
        if signedIn {
            try store.save(GitCredential(username: "someone", token: Self.token), forHost: "github.com")
        }
        var service = GitHubRepositoryService(credentials: store)
        service.exchange = github.exchange
        return service
    }

    func testAPrivateRepositoryOnTheAccountIsMadeEmpty() async throws {
        let github = FakeGitHub()
        let request = GitRepositoryCreateRequest(name: "clock-tweak", visibility: .private, description: "A clock in the status bar")
        let response = try await service(github: github).create(request)
        XCTAssertEqual(response, GitRepositoryCreateResponse(
            fullName: "someone/clock-tweak",
            cloneURL: "https://github.com/someone/clock-tweak.git",
            url: "https://github.com/someone/clock-tweak",
        ))
        XCTAssertEqual(github.requests.map { "\($0.method) \($0.path)" }, ["POST /user/repos"], "no owner named: nothing to tell apart")
        let body = try XCTUnwrap(github.requests.first?.body)
        XCTAssertEqual(Set(body.keys), ["name", "private", "auto_init", "description"], "GitHub's defaults for the rest")
        XCTAssertEqual(body["private"] as? Bool, true)
        XCTAssertEqual(body["auto_init"] as? Bool, false, "no README, so a first push lays down the history")
        XCTAssertEqual(body["description"] as? String, "A clock in the status bar")
    }

    func testAnOrganizationIsNamedByItsLoginAndTheAccountsOwnIsTheAccount() async throws {
        let github = FakeGitHub()
        github.organizations = ["OwnGoal": true]
        let service = try service(github: github)
        let organization = try await service.create(GitRepositoryCreateRequest(name: "tools", visibility: .public, owner: "OwnGoal"))
        XCTAssertEqual(organization.fullName, "OwnGoal/tools")
        let own = try await service.create(GitRepositoryCreateRequest(name: "tools", visibility: .public, owner: "Someone"))
        XCTAssertEqual(own.fullName, "someone/tools", "the account's own login, however it is spelt")
        let made = github.requests.filter { $0.method == "POST" }
        XCTAssertEqual(made.map(\.path), ["/orgs/OwnGoal/repos", "/user/repos"])
        XCTAssertTrue(made.allSatisfy { $0.body?["private"] as? Bool == false })
    }

    func testGitHubsRefusalsComeBackInItsWords() async throws {
        let github = FakeGitHub()
        github.taken = ["someone/clock-tweak"]
        github.organizations = ["ReadOnly": false]
        let service = try service(github: github)
        let refused: [(GitRepositoryCreateRequest, ApelinError.Code, String)] = [
            (GitRepositoryCreateRequest(name: "clock-tweak", visibility: .public), .conflict, "name already exists on this account"),
            (GitRepositoryCreateRequest(name: "tools", visibility: .private, owner: "Nowhere"), .notFound, "no organization Nowhere"),
            (GitRepositoryCreateRequest(name: "tools", visibility: .private, owner: "ReadOnly"), .denied, "admin access to the organization"),
        ]
        for (request, code, words) in refused {
            do {
                _ = try await service.create(request)
                XCTFail("made \(request.owner ?? "")/\(request.name)")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, code, error.message)
                XCTAssertTrue(error.message.contains(words), error.message)
                XCTAssertFalse(error.description.contains(Self.token))
            }
        }
    }

    func testWithoutASignInItSaysSoAndAsksNothingOfGitHub() async throws {
        let github = FakeGitHub()
        do {
            _ = try await service(github: github, signedIn: false).create(GitRepositoryCreateRequest(name: "tools", visibility: .private))
            XCTFail("made without a sign-in")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .denied)
            XCTAssertEqual(error.reason, .authenticationRequired)
            XCTAssertTrue(error.message.contains("Settings ▸ Git"), error.message)
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testARefusedRequestReachesNobody() async throws {
        let github = FakeGitHub()
        // Signed out too: the request is refused before the sign-in is read.
        let service = try service(github: github, signedIn: false)
        let refused = [
            GitRepositoryCreateRequest(name: "not a name", visibility: .private),
            GitRepositoryCreateRequest(name: "", visibility: .private),
            GitRepositoryCreateRequest(name: "tools.git", visibility: .private),
            GitRepositoryCreateRequest(name: "tools", visibility: .private, owner: "-OwnGoal"),
            GitRepositoryCreateRequest(name: "tools", visibility: .private, description: "Two\nlines"),
            GitRepositoryCreateRequest(name: "tools", visibility: .private, description: String(repeating: "a", count: 351)),
        ]
        for request in refused {
            do {
                _ = try await service.create(request)
                XCTFail("made \(request.name)")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .badRequest, error.message)
            }
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testTheWorkerServesIt() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        worker.repositories = try service(github: github)
        let request = GitRepositoryCreateRequest(name: "tools", visibility: .private)
        let (reply, _) = try await worker.handle(ChannelRequest(request: WireRequest(request), descriptors: [], taskID: nil))
        let response = try JSONCoding.decode(GitRepositoryCreateResponse.self, from: reply.result.get())
        XCTAssertEqual(response.cloneURL, "https://github.com/someone/tools.git")
        XCTAssertEqual(github.requests.count, 1)
    }

    /// The wire names the visibility, always: a request without it does
    /// not decode.
    func testTheVisibilityIsAlwaysNamed() throws {
        func decode(_ json: String) throws -> GitRepositoryCreateRequest {
            try JSONCoding.decode(GitRepositoryCreateRequest.self, from: Data(json.utf8))
        }
        XCTAssertThrowsError(try decode(#"{"name": "tools"}"#))
        XCTAssertThrowsError(try decode(#"{"name": "tools", "visibility": "internal"}"#))
        XCTAssertEqual(try decode(#"{"name": "tools", "visibility": "public"}"#).visibility, GitRepositoryVisibility.public)
    }
}
