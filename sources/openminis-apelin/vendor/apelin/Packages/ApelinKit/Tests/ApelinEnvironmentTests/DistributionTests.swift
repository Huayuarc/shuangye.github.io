import ApelinCore
import ApelinDebArchive
import ApelinDebian
@testable import ApelinEnvironment
@testable import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import Foundation
import XCTest

/// The package repository: GitHub's API answered by a fake, the repository
/// itself a bare one on disk, the github.com sign-in in memory.
final class DistributionTests: XCTestCase {
    /// GitHub as far as a package repository asks it: the account, its
    /// repositories, and Pages, noting each request.
    final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        var login = "someone"
        var repositories: [String: [String: Any]] = [:]
        var pages: [String: [String: Any]] = [:]
        var refusePages = false
        var organizations: [String] = []
        private(set) var requests: [(method: String, path: String, body: [String: Any]?)] = []

        func repository(_ name: String, owner: String? = nil, defaultBranch: String = "main", push: Bool = true) -> [String: Any] {
            let owner = owner ?? login
            return [
                "name": name, "full_name": "\(owner)/\(name)", "owner": ["login": owner], "private": false,
                "description": NSNull(), "html_url": "https://github.com/\(owner)/\(name)",
                "clone_url": "https://github.com/\(owner)/\(name).git", "default_branch": defaultBranch,
                "has_pages": false, "permissions": ["push": push],
            ]
        }

        var exchange: GitHubAPI.Exchange {
            { request in try self.answer(request) }
        }

        private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_token")
            let method = request.httpMethod ?? "GET"
            let path = request.url!.path
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return lock.withLock {
                requests.append((method, path, body))
                func reply(_ status: Int, _ object: Any) -> (Data, HTTPURLResponse) {
                    let data = try! JSONSerialization.data(withJSONObject: object)
                    return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                switch (method, path) {
                case ("GET", "/user"):
                    return reply(200, ["login": login])
                case ("GET", "/user/repos"):
                    return reply(200, Array(repositories.values))
                case ("GET", "/user/orgs"):
                    return reply(200, organizations.map { ["login": $0] })
                case ("POST", "/user/repos"):
                    let name = body?["name"] as? String ?? ""
                    guard repositories["\(login)/\(name)"] == nil else {
                        return reply(422, ["message": "Repository creation failed.", "errors": [["message": "name already exists on this account"]]])
                    }
                    repositories["\(login)/\(name)"] = repository(name)
                    return reply(201, repositories["\(login)/\(name)"]!)
                default:
                    break
                }
                let parts = path.split(separator: "/").map(String.init)
                if method == "POST", parts.count == 3, parts[0] == "orgs", parts[2] == "repos" {
                    let name = body?["name"] as? String ?? ""
                    repositories["\(parts[1])/\(name)"] = repository(name, owner: parts[1])
                    return reply(201, repositories["\(parts[1])/\(name)"]!)
                }
                guard parts.count >= 3, parts[0] == "repos" else { return reply(404, ["message": "Not Found"]) }
                let fullName = parts[1] + "/" + parts[2]
                guard let repository = repositories[fullName] else { return reply(404, ["message": "Not Found"]) }
                if parts.count == 3, method == "GET" {
                    return reply(200, repository)
                }
                guard parts.count == 4, parts[3] == "pages" else { return reply(404, ["message": "Not Found"]) }
                let site = ["html_url": "https://\(parts[1].lowercased()).github.io/\(parts[2])/", "build_type": body?["build_type"] as? String ?? "workflow"]
                switch method {
                case "GET":
                    return pages[fullName].map { reply(200, $0) } ?? reply(404, ["message": "Not Found"])
                case "POST":
                    if refusePages {
                        return reply(422, ["message": "Your current plan does not support GitHub Pages for this repository."])
                    }
                    pages[fullName] = site
                    return reply(201, site)
                case "PUT":
                    pages[fullName] = site
                    return reply(204, [String: Any]())
                default:
                    return reply(404, ["message": "Not Found"])
                }
            }
        }
    }

    private struct Fixture {
        let home: TemporaryHome
        let github = FakeGitHub()
        let service: DistributionService
        let remotes: URL
        let store = MemoryGitCredentialStore()

        init(_ test: XCTestCase, signedIn: Bool = true) throws {
            home = try TemporaryHome(test)
            remotes = home.home.appendingPathComponent("remotes", isDirectory: true)
            let store = store
            if signedIn {
                try store.save(GitCredential(username: "someone", token: "gho_token"), forHost: "github.com")
            }
            var git = GitService(layout: home.layout, credentials: store)
            git.acceptsLocalRemotes = true
            var service = DistributionService(layout: home.layout, git: git, credentials: store)
            service.exchange = github.exchange
            let remotes = remotes
            service.remoteURL = { remotes.appendingPathComponent($0 + ".git").path }
            self.service = service
        }

        /// The bare repository GitHub would hold for `owner/name`.
        func bare(_ fullName: String) throws -> URL {
            let url = remotes.appendingPathComponent(fullName + ".git", isDirectory: true)
            try GitRepository.createBare(at: url)
            return url
        }

        func project(_ name: String) -> URL {
            home.layout.data.projects.appendingPathComponent(name, isDirectory: true)
        }

        /// A package as a build leaves it, under `Builds/`.
        func build(_ package: String, version: String, architecture: String = "iphoneos-arm64", marker: UInt8 = 1) throws -> URL {
            var control = DebianControlFile(package: package, version: version, architecture: architecture, description: "Test")
            control["Section"] = "Tweaks"
            var writer = DebPackageWriter(control: control)
            writer.controlCompression = .gzip
            writer.entries = [.file("/var/jb/usr/share/test/\(package)", contents: Data([marker]))]
            let folder = home.layout.data.root.appendingPathComponent("Builds/p/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("out.deb")
            try writer.write(toPath: url.path)
            return url
        }

        /// What a build records of its package: `sha256:` of its bytes.
        func digest(_ url: URL) throws -> String {
            try CanonicalJSON.sha256Tag(Data(contentsOf: url))
        }

        /// A publish in a task's own staging, as the worker runs one.
        func publish(_ linked: DistributionRepository, files: [URL], digests: [String]? = nil) async throws -> JSONValue {
            let staging = try home.layout.makeStaging(UUID().uuidString)
            return try await service.publish(linked, files: files, digests: digests, staging: staging, reporter: .silent)
        }

        /// The packages in the repository's clone, its README aside.
        func published(_ project: String = "packages") -> [String] {
            let debs = self.project(project).appendingPathComponent("debs").path
            let names = (try? FileManager.default.contentsOfDirectory(atPath: debs)) ?? []
            return names.filter { $0.hasSuffix(".deb") }.sorted()
        }
    }

    /// The subjects of the bare repository's main, newest first, as git
    /// itself reads them.
    private func commits(in bare: URL) throws -> [String] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["--git-dir=\(bare.path)", "log", "--format=%s", "main"]
        let output = Pipe()
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        try git.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: Create

    func testCreateMakesTheRepositoryProjectCommitPagesAndLink() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/packages")
        let name = try fixture.service.prepareCreate(DistributionRepositoryCreateRequest(name: "packages"))
        let log = EventLog()
        let result = try await fixture.service.create(DistributionRepositoryCreateRequest(name: name), name: name, reporter: log.reporter)

        let stages = log.events.filter { $0.0 == "stage" }.compactMap { $0.1?["stage"]?.stringValue }
        XCTAssertEqual(stages, ["creating", "preparing", "pushing", "publishing"])
        let root = fixture.project("packages")
        for path in [DistributionTemplate.workflowPath, "scripts/update-repository.sh", "index.html", "README.md", "debs/README.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        let workflow = try String(contentsOf: root.appendingPathComponent(DistributionTemplate.workflowPath), encoding: .utf8)
        XCTAssertTrue(workflow.contains("- main\n"), "the workflow runs on the branch packages go to")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("scripts/update-repository.sh").path))
        XCTAssertEqual(try commits(in: bare), ["Set up the package repository"])
        let status = try GitService(layout: fixture.home.layout).status(GitStatusRequest(projectID: "packages"))
        XCTAssertEqual(status.entries, [], "Apelin's own files stay out of the repository")

        let pages = fixture.github.requests.filter { $0.path == "/repos/someone/packages/pages" && $0.method == "POST" }
        XCTAssertEqual(pages.first?.body?["build_type"] as? String, "workflow")
        let linked = try XCTUnwrap(result["repository"]?.decode(DistributionRepository.self))
        XCTAssertEqual(linked.fullName, "someone/packages")
        XCTAssertEqual(linked.sourceURL, "https://someone.github.io/packages/")
        XCTAssertEqual(linked.projectName, "packages")
        let listed = try await fixture.service.list(DistributionRepositoryListRequest(repositories: true))
        XCTAssertEqual(listed.account, "someone")
        XCTAssertEqual(listed.linked, linked)
        XCTAssertEqual(listed.repositories.map(\.fullName), ["someone/packages"])
    }

    func testCreateInAnOrganizationAndListItsRepositories() async throws {
        let fixture = try Fixture(self)
        fixture.github.organizations = ["OwnGoal"]
        fixture.github.repositories["Readers/notes"] = fixture.github.repository("notes", owner: "Readers", push: false)
        fixture.github.repositories["Team/site"] = fixture.github.repository("site", owner: "Team")
        let bare = try fixture.bare("OwnGoal/packages")
        let request = DistributionRepositoryCreateRequest(name: "packages", owner: "OwnGoal")
        let name = try fixture.service.prepareCreate(request)
        let result = try await fixture.service.create(request, name: name, reporter: EventLog().reporter)

        XCTAssertTrue(fixture.github.requests.contains { $0.method == "POST" && $0.path == "/orgs/OwnGoal/repos" })
        XCTAssertFalse(fixture.github.requests.contains { $0.method == "POST" && $0.path == "/user/repos" })
        XCTAssertEqual(try commits(in: bare), ["Set up the package repository"])
        let linked = try XCTUnwrap(result["repository"]?.decode(DistributionRepository.self))
        XCTAssertEqual(linked.fullName, "OwnGoal/packages")
        XCTAssertEqual(linked.sourceURL, "https://owngoal.github.io/packages/")

        let listed = try await fixture.service.list(DistributionRepositoryListRequest(repositories: true))
        XCTAssertEqual(Set(listed.repositories.map(\.fullName)), ["OwnGoal/packages", "Team/site"], "one it cannot push to is left out")
        XCTAssertEqual(listed.organizations, ["OwnGoal", "Team"])

        // the account's own login is the account, not an organization
        let own = DistributionRepositoryCreateRequest(name: "own", owner: "someone")
        _ = try fixture.bare("someone/own")
        _ = try await fixture.service.create(own, name: fixture.service.prepareCreate(own), reporter: EventLog().reporter)
        XCTAssertTrue(fixture.github.requests.contains { $0.method == "POST" && $0.path == "/user/repos" })
        for owner in ["", "-team", "a--b", "has space", String(repeating: "a", count: 40)] {
            XCTAssertThrowsError(try fixture.service.prepareCreate(DistributionRepositoryCreateRequest(name: "x", owner: owner)), owner)
        }
    }

    func testCreateIsCheckedBeforeItStarts() throws {
        let fixture = try Fixture(self)
        for name in ["", "two words", "a/b", "..", "x.git", String(repeating: "a", count: 101)] {
            XCTAssertThrowsError(try fixture.service.prepareCreate(DistributionRepositoryCreateRequest(name: name)), name) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, name)
            }
        }
        _ = try ProjectStore(dataFolder: fixture.home.layout.data).createEmpty(name: "taken")
        XCTAssertThrowsError(try fixture.service.prepareCreate(DistributionRepositoryCreateRequest(name: "taken"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
        }
        let signedOut = try Fixture(self, signedIn: false)
        XCTAssertThrowsError(try signedOut.service.prepareCreate(DistributionRepositoryCreateRequest(name: "packages"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .denied)
            XCTAssertEqual(($0 as? ApelinError)?.reason?.rawValue, "authenticationRequired")
        }
    }

    func testAPagesRefusalIsAWarningAndTheLinkIsKept() async throws {
        let fixture = try Fixture(self)
        _ = try fixture.bare("someone/private-packages")
        fixture.github.refusePages = true
        let log = EventLog()
        let result = try await fixture.service.create(
            DistributionRepositoryCreateRequest(name: "private-packages"),
            name: "private-packages",
            reporter: log.reporter,
        )
        guard case let .array(warnings)? = result["warnings"] else { return XCTFail("no warnings") }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].stringValue?.contains("GitHub Actions") == true)
        XCTAssertEqual(log.kinds.filter { $0 == "warning" }.count, 1)
        XCTAssertNotNil(fixture.service.linked())
    }

    // MARK: Link

    func testLinkClonesAddsWhatTheTemplateHasAndKeepsWhatIsThere() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/apt")
        // the user's repository, with an index page of its own
        let seed = try GitRepository.create(at: fixture.home.home.appendingPathComponent("seed", isDirectory: true))
        try Data("mine\n".utf8).write(to: seed.workdir.appendingPathComponent("index.html"))
        try seed.stage(["index.html"])
        try seed.commit(message: "My page", author: GitSignature(name: "Someone", email: "someone@apelin.invalid"))
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        fixture.github.repositories["someone/apt"] = fixture.github.repository("apt")
        fixture.github.pages["someone/apt"] = ["html_url": "https://someone.github.io/apt/", "build_type": "legacy"]

        try fixture.service.prepareLink(DistributionRepositoryLinkRequest(fullName: "someone/apt"))
        let result = try await fixture.service.link(DistributionRepositoryLinkRequest(fullName: "someone/apt"), reporter: .silent)
        let root = fixture.project("apt")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8), "mine\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(DistributionTemplate.workflowPath).path))
        XCTAssertEqual(try commits(in: bare), ["Add the package index and its GitHub Pages workflow", "My page"])
        XCTAssertTrue(fixture.github.requests.contains { $0.method == "PUT" && $0.path == "/repos/someone/apt/pages" },
                      "a branch-built site is switched to the workflow")
        XCTAssertEqual(try result["repository"]?.decode(DistributionRepository.self).projectName, "apt")

        // linked again: the same project, nothing to add or push
        _ = try await fixture.service.link(DistributionRepositoryLinkRequest(fullName: "someone/apt"), reporter: .silent)
        XCTAssertEqual(try commits(in: bare).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project("apt 2").path))
    }

    func testUpdateReplacesWhatTheTemplateMaintainsAndKeepsTheRest() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/apt")
        let seed = try GitRepository.create(at: fixture.home.home.appendingPathComponent("seed", isDirectory: true))
        try FileManager.default.createDirectory(at: seed.workdir.appendingPathComponent("debs"), withIntermediateDirectories: true)
        let mine: [(String, String)] = [
            ("index.html", "old page\n"), ("README.md", "old readme\n"),
            ("sileo-featured.json", "{\"banners\": []}\n"), ("debs/a_1_iphoneos-arm64.deb", "deb\n"),
        ]
        for (path, text) in mine {
            try Data(text.utf8).write(to: seed.workdir.appendingPathComponent(path))
        }
        try seed.stage(mine.map(\.0))
        try seed.commit(message: "Old template", author: GitSignature(name: "Someone", email: "someone@apelin.invalid"))
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        fixture.github.repositories["someone/apt"] = fixture.github.repository("apt")

        _ = try await fixture.service.link(DistributionRepositoryLinkRequest(fullName: "someone/apt", overwrite: true), reporter: .silent)
        let root = fixture.project("apt")
        let page = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(page.contains("Open in Irisin"), "the page is the template's")
        XCTAssertFalse(page.contains("Sileo"))
        XCTAssertNotEqual(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8), "old readme\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("CydiaIcon.png")), DistributionTemplate.icon)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sileo-featured.json"), encoding: .utf8), "{\"banners\": []}\n",
                       "the user's banners stay")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("debs/a_1_iphoneos-arm64.deb"), encoding: .utf8), "deb\n")
        XCTAssertEqual(try commits(in: bare), ["Update the package repository from Apelin's template", "Old template"])

        // already up to date: nothing to commit
        _ = try await fixture.service.link(DistributionRepositoryLinkRequest(fullName: "someone/apt", overwrite: true), reporter: .silent)
        XCTAssertEqual(try commits(in: bare).count, 2)
    }

    func testLinkSetsUpAnEmptyRepository() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/empty")
        fixture.github.repositories["someone/empty"] = fixture.github.repository("empty")
        _ = try await fixture.service.link(DistributionRepositoryLinkRequest(fullName: "someone/empty"), reporter: .silent)
        XCTAssertEqual(try commits(in: bare), ["Add the package index and its GitHub Pages workflow"])
        XCTAssertEqual(fixture.service.linked()?.fullName, "someone/empty")
    }

    func testLinkIsCheckedBeforeItStarts() throws {
        let fixture = try Fixture(self)
        for name in ["", "someone", "a/b/c", "someone/two words"] {
            XCTAssertThrowsError(try fixture.service.prepareLink(DistributionRepositoryLinkRequest(fullName: name)), name) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, name)
            }
        }
    }

    // MARK: Publish

    func testPublishCopiesCommitsAndPushesEachPackageOnce() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/packages")
        _ = try await fixture.service.create(DistributionRepositoryCreateRequest(name: "packages"), name: "packages", reporter: .silent)
        let rootless = try fixture.build("com.example.tweak", version: "1:1.0")
        let roothide = try fixture.build("com.example.tweak", version: "1:1.0", architecture: "iphoneos-arm64e")
        let (linked, files) = try fixture.service.preparePublish(DistributionPublishRequest(files: [rootless.path, roothide.path]))
        let result = try await fixture.publish(linked, files: files)
        let names = ["com.example.tweak_1%3a1.0_iphoneos-arm64.deb", "com.example.tweak_1%3a1.0_iphoneos-arm64e.deb"]
        XCTAssertEqual(result["published"], .array(names.map(JSONValue.string)))
        XCTAssertEqual(result["repository"], .string("someone/packages"))
        for name in names {
            XCTAssertTrue(FileManager.default.contentsEqual(
                atPath: fixture.project("packages").appendingPathComponent("debs/\(name)").path,
                andPath: (name.hasSuffix("arm64e.deb") ? roothide : rootless).path,
            ))
        }
        XCTAssertEqual(try commits(in: bare), ["Publish com.example.tweak 1:1.0", "Set up the package repository"])

        // the same bytes again are skipped; other bytes under the name are
        // refused, and so is the new package beside them
        let again = try await fixture.publish(linked, files: [rootless])
        XCTAssertEqual(again["skipped"], .array([.string(names[0])]))
        XCTAssertNil(again["commit"])
        let newer = try fixture.build("com.example.tweak", version: "1:1.1")
        let changed = try fixture.build("com.example.tweak", version: "1:1.0", marker: 2)
        do {
            _ = try await fixture.publish(linked, files: [newer, changed])
            XCTFail("a changed package under a published name must be refused")
        } catch {
            XCTAssertEqual((error as? ApelinError)?.code, .conflict, "\(error)")
        }
        XCTAssertEqual(fixture.published(), names, "nothing went in")
        XCTAssertEqual(try commits(in: bare).count, 2)
    }

    func testPublishHoldsEachPackageToItsDigestAndPublishesNoneWhenOneDiffers() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/packages")
        _ = try await fixture.service.create(DistributionRepositoryCreateRequest(name: "packages"), name: "packages", reporter: .silent)
        let roothide = try fixture.build("com.example.tweak", version: "1.0", architecture: "iphoneos-arm64e")
        let rootless = try fixture.build("com.example.tweak", version: "1.0")
        let other = try fixture.build("com.example.tweak", version: "1.0", marker: 2)
        let request = try DistributionPublishRequest(
            files: [roothide.path, rootless.path],
            digests: [fixture.digest(roothide), fixture.digest(other)],
            repository: "someone/packages",
        )
        let (linked, files) = try fixture.service.preparePublish(request)
        do {
            _ = try await fixture.publish(linked, files: files, digests: request.digests)
            XCTFail("a package whose bytes are not its digest must be refused")
        } catch {
            XCTAssertEqual((error as? ApelinError)?.code, .conflict, "\(error)")
            XCTAssertTrue("\(error)".contains("none of the packages went in"), "\(error)")
        }
        XCTAssertEqual(fixture.published(), [], "neither package went in, the one that matched included")
        XCTAssertEqual(try commits(in: bare), ["Set up the package repository"])

        // both bootstraps of one version, held to their digests, in one commit
        let digests = try [fixture.digest(roothide), fixture.digest(rootless)]
        let result = try await fixture.publish(linked, files: files, digests: digests)
        let names = ["com.example.tweak_1.0_iphoneos-arm64.deb", "com.example.tweak_1.0_iphoneos-arm64e.deb"]
        XCTAssertEqual(result["published"], .array(names.reversed().map(JSONValue.string)), "in the request's order")
        XCTAssertEqual(fixture.published(), names)
        XCTAssertEqual(try commits(in: bare), ["Publish com.example.tweak 1.0", "Set up the package repository"])
        for (name, source) in zip(names, [rootless, roothide]) {
            let copy = fixture.project("packages").appendingPathComponent("debs/\(name)")
            XCTAssertEqual(try fixture.digest(copy), try fixture.digest(source), "\(name) as its build made it")
        }

        // two packages that would take one name publish neither
        let twin = try fixture.build("com.example.other", version: "2.0")
        let sameName = try fixture.build("com.example.other", version: "2.0", marker: 3)
        do {
            _ = try await fixture.publish(linked, files: [twin, sameName])
            XCTFail("two packages of one name must be refused")
        } catch {
            XCTAssertEqual((error as? ApelinError)?.code, .badRequest, "\(error)")
        }
        XCTAssertEqual(fixture.published(), names)
    }

    func testAPublishWhosePushFailedReachesGitHubWithTheNextOne() async throws {
        let fixture = try Fixture(self)
        let bare = try fixture.bare("someone/packages")
        _ = try await fixture.service.create(DistributionRepositoryCreateRequest(name: "packages"), name: "packages", reporter: .silent)
        let built = try fixture.build("com.example.tweak", version: "1.0")
        let name = "com.example.tweak_1.0_iphoneos-arm64.deb"
        // what a publish leaves when its push fails: the package committed in the clone only
        let clone = fixture.project("packages")
        try FileManager.default.copyItem(at: built, to: clone.appendingPathComponent("debs/\(name)"))
        let repository = try GitRepository(at: clone)
        try repository.stage(["debs/\(name)"])
        let author = GitSignature(name: "someone", email: "someone@users.noreply.github.com")
        _ = try repository.commit(message: "Publish com.example.tweak 1.0", author: author)
        XCTAssertEqual(try commits(in: bare), ["Set up the package repository"])

        let (linked, files) = try fixture.service.preparePublish(DistributionPublishRequest(files: [built.path]))
        let result = try await fixture.publish(linked, files: files)
        XCTAssertEqual(result["skipped"], .array([.string(name)]))
        XCTAssertNil(result["commit"], "nothing new to commit")
        XCTAssertEqual(try commits(in: bare), ["Publish com.example.tweak 1.0", "Set up the package repository"])
    }

    func testPublishChecksItsDigestsRepositoryAndSignInBeforeItStarts() async throws {
        let fixture = try Fixture(self)
        _ = try fixture.bare("someone/packages")
        _ = try await fixture.service.create(DistributionRepositoryCreateRequest(name: "packages"), name: "packages", reporter: .silent)
        let built = try fixture.build("com.example.tweak", version: "1.0")
        let digest = try fixture.digest(built)
        let malformed: [[String]] = [
            [], [digest, digest], ["sha256:" + String(repeating: "A", count: 64)], [String(digest.dropFirst(7))], ["sha256:12"],
        ]
        for digests in malformed {
            XCTAssertThrowsError(try fixture.service.preparePublish(DistributionPublishRequest(files: [built.path], digests: digests))) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, "\(digests)")
            }
        }
        XCTAssertThrowsError(try fixture.service.preparePublish(DistributionPublishRequest(
            files: [built.path], digests: [digest], repository: "someone/elsewhere",
        ))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict, "another repository than the one linked")
        }
        XCTAssertNoThrow(try fixture.service.preparePublish(DistributionPublishRequest(
            files: [built.path], digests: [digest], repository: "Someone/Packages",
        )), "GitHub's names take any case")
        XCTAssertNoThrow(try fixture.service.preparePublish(DistributionPublishRequest(files: [built.path])), "as the app sends it")

        try fixture.store.remove(host: "github.com")
        XCTAssertThrowsError(try fixture.service.preparePublish(DistributionPublishRequest(files: [built.path]))) {
            XCTAssertEqual(($0 as? ApelinError)?.reason, .authenticationRequired, "nothing can be pushed without a sign-in")
        }
    }

    func testPublishTakesOnlyBuiltPackagesAndNeedsALink() throws {
        let fixture = try Fixture(self)
        let outside = fixture.home.home.appendingPathComponent("elsewhere.deb")
        try Data("x".utf8).write(to: outside)
        for files in [[], [outside.path], ["/etc/hosts"], Array(repeating: outside.path, count: 17)] {
            XCTAssertThrowsError(try fixture.service.preparePublish(DistributionPublishRequest(files: files))) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
            }
        }
        let built = try fixture.build("com.example.tweak", version: "1.0")
        XCTAssertThrowsError(try fixture.service.preparePublish(DistributionPublishRequest(files: [built.path]))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound, "no link yet")
        }
    }

    // MARK: Pieces

    func testAnOriginIsTheSameRepositoryHoweverItIsSpelled() {
        let forms = ["https://github.com/Someone/apt.git", "https://github.com/someone/apt", "https://github.com/someone/apt/"]
        XCTAssertEqual(Set(forms.map(DistributionService.comparable)).count, 1)
        XCTAssertNotEqual(DistributionService.comparable("https://github.com/someone/apt2"), DistributionService.comparable(forms[0]))
    }

    func testNamesAndAddresses() throws {
        XCTAssertEqual(DistributionService.sourceURL(owner: "Someone", name: "packages"), "https://someone.github.io/packages/")
        XCTAssertEqual(DistributionService.sourceURL(owner: "Someone", name: "someone.github.io"), "https://someone.github.io/")
        XCTAssertEqual(
            try DistributionService.packageFileName(package: "com.a.b", version: "2:1.0~beta+1", architecture: "iphoneos-arm64"),
            "com.a.b_2%3a1.0~beta+1_iphoneos-arm64.deb",
        )
        XCTAssertThrowsError(try DistributionService.packageFileName(package: "../x", version: "1", architecture: "a"))
        XCTAssertThrowsError(try DistributionService.packageFileName(package: "x", version: "1 2", architecture: "a"))
    }

    func testGitHubRefusalsBecomeApelinErrors() {
        func refusal(_ status: Int, _ body: String) -> ApelinError? {
            let response = HTTPURLResponse(url: GitHubAPI.base, statusCode: status, httpVersion: nil, headerFields: nil)!
            do {
                try GitHubAPI.check(response, Data(body.utf8))
                return nil
            } catch {
                return error as? ApelinError
            }
        }
        XCTAssertNil(refusal(204, ""))
        XCTAssertEqual(refusal(401, #"{"message":"Bad credentials"}"#)?.reason?.rawValue, "authenticationRequired")
        XCTAssertEqual(refusal(404, "")?.code, .notFound)
        let taken = refusal(422, #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#)
        XCTAssertEqual(taken?.code, .conflict)
        XCTAssertTrue(taken?.message.contains("name already exists") == true)
        XCTAssertEqual(refusal(502, "<html>")?.code, .unavailable)
    }
}
