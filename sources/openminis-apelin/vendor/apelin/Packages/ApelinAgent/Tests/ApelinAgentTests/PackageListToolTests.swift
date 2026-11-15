@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import struct ApelinProtocol.ApelinError
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// apelin_package_list finds an installation from any conversation, and
/// apelin_package_remove takes its id or the package id alone: the removal
/// stays bound to one installation id, which the card names and the host
/// spends.
@Suite("Installed packages")
struct PackageListToolTests {
    private static let removable = ListedInstallation(
        installationID: "11111111-1111-4111-8111-111111111111",
        packageID: "local.apelin.dockflip",
        version: "1.2",
        projectID: "project-dockflip",
        project: "DockFlip",
        buildID: "build-7",
        installedAt: Date(timeIntervalSince1970: 1_790_000_000),
        removable: true,
    )
    private static let changedElsewhere = ListedInstallation(
        installationID: "22222222-2222-4222-8222-222222222222",
        packageID: "local.apelin.nailong",
        version: "1.0",
        projectID: "project-nailong",
        project: "Nailong",
        installedAt: Date(timeIntervalSince1970: 1_780_000_000),
        removable: false,
        reason: "local.apelin.nailong is now version 2.0, not version 1.0 that Apelin installed. Remove it with your preferred package manager.",
    )

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap {
            if case let .text(text) = $0 {
                text.text
            } else {
                nil
            }
        }.joined()
    }

    private func message(_ error: any Error) -> String {
        (error as? ToolDeniedError)?.message ?? (error as? ToolArgumentError)?.message ?? "\(error)"
    }

    @Test
    func `the list is a read that never asks, filtered by package and project`() async throws {
        #expect(AgentToolName.packageList.rawValue == "apelin_package_list")
        #expect(AgentToolName.packageList.risk == .readOnly && !AgentToolName.packageList.isProjectOnly)
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.removable, Self.changedElsewhere])
        try await harness.backend.addProject(ProjectIdentity(id: "project-nailong", name: ProjectName("Nailong")))

        let (all, asked) = try await harness.run(.packageList, [:])
        #expect(asked.isEmpty, "Strict mode lists without asking")
        let listed = try JSONDecoder.iso8601.decode(InstallationListToolResponse.self, from: Data(text(all).utf8))
        #expect(listed.installations == [Self.removable, Self.changedElsewhere])

        let (byPackage, _) = try await harness.run(.packageList, ["package_id": "local.apelin.dockflip"])
        #expect(text(byPackage).contains(Self.removable.installationID) && !text(byPackage).contains("nailong"))
        let (byProject, _) = try await harness.run(.packageList, ["project": "Nailong"])
        #expect(text(byProject).contains(Self.changedElsewhere.installationID) && !text(byProject).contains("dockflip"))
        #expect(await harness.backend.installationQueries.last == InstallationListToolRequest(projectID: "project-nailong"))
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `a package id resolves to its one removable installation, which the card names and binds`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.removable, Self.changedElsewhere])

        let (_, asked) = try await harness.run(.packageRemove, ["package_id": "local.apelin.dockflip"])
        #expect(asked.count == 1 && asked.first?.allowsSessionScope == false)
        #expect(asked.first?.detail == .packageRemoval(installationID: Self.removable.installationID))
        #expect(asked.first?.reason == "Removing local.apelin.dockflip 1.2, installed by the project DockFlip, requires your approval.")
        #expect(await harness.backend.calls == [.removePackage(Self.removable.installationID)])

        // Relaxed removes it without asking, by the same installation.
        let relaxed = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { relaxed.home.remove() }
        await relaxed.backend.setInstallations([Self.removable])
        let (_, relaxedAsked) = try await relaxed.run(.packageRemove, ["package_id": "local.apelin.dockflip"])
        #expect(relaxedAsked.isEmpty)
        #expect(await relaxed.backend.calls == [.removePackage(Self.removable.installationID)])
    }

    @Test
    func `a package id with nothing Apelin can remove is refused before asking, with why`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.changedElsewhere])
        do {
            _ = try await harness.run(.packageRemove, ["package_id": "local.apelin.nailong"])
            Issue.record("a package Apelin cannot remove is refused")
        } catch {
            #expect(message(error).contains(Self.changedElsewhere.installationID))
            #expect(message(error).contains("now version 2.0"))
        }
        do {
            _ = try await harness.run(.packageRemove, ["package_id": "com.example.foreign"])
            Issue.record("a package Apelin never installed is refused")
        } catch {
            #expect(message(error).contains("package manager") && message(error).contains("apelin_package_list"))
        }
        #expect(await harness.events.events.isEmpty, "nothing was asked")
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `both arguments or neither are refused, naming the one to give`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.removable])
        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.packageRemove, [:])
        }
        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.packageRemove, [
                "installation_id": .string(Self.removable.installationID), "package_id": "local.apelin.dockflip",
            ])
        }
        // An empty one is one left out, as a model fills it.
        let (_, asked) = try await harness.run(.packageRemove, [
            "installation_id": .string(Self.removable.installationID), "package_id": "",
        ])
        #expect(asked.first?.detail == .packageRemoval(installationID: Self.removable.installationID))
        #expect(asked.first?.reason.contains("local.apelin.dockflip 1.2") == true, "an id the list shows is named on the card")
    }

    @Test
    func `an installation id the list shows as not removable is refused before asking`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.changedElsewhere])
        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(.packageRemove, ["installation_id": .string(Self.changedElsewhere.installationID)])
        }
        #expect(await harness.events.events.isEmpty)
    }

    @Test
    func `an installation id the list does not show is refused before asking, with what Apelin can remove`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.removable, Self.changedElsewhere])
        do {
            _ = try await harness.run(.packageRemove, ["installation_id": "33333333-3333-4333-8333-333333333333"])
            Issue.record("an id Apelin does not list is refused")
        } catch {
            let text = message(error)
            #expect(text.hasPrefix("Apelin has no installation 33333333-3333-4333-8333-333333333333 it can remove"))
            #expect(text.contains("\(Self.removable.installationID) (local.apelin.dockflip 1.2, project DockFlip)"))
            #expect(!text.contains(Self.changedElsewhere.installationID), "only what can be removed is offered")
        }
        #expect(await harness.events.events.isEmpty, "nothing was asked")
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `without the whole list the host decides, and its refusal names what Apelin can remove instead`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { harness.home.remove() }
        await harness.backend.setInstallations([Self.removable, Self.changedElsewhere], truncated: true)
        await harness.backend.setRemovalRefusal(ApelinError(
            .notFound,
            "Apelin did not install this package. Remove it with your preferred package manager.",
        ))
        do {
            _ = try await harness.run(.packageRemove, ["installation_id": "33333333-3333-4333-8333-333333333333"])
            Issue.record("the host's refusal reaches the model")
        } catch {
            let text = message(error)
            #expect(text.hasPrefix("Apelin did not install this package."))
            #expect(text.contains("\(Self.removable.installationID) (local.apelin.dockflip 1.2, project DockFlip)"))
            #expect(!text.contains(Self.changedElsewhere.installationID), "only what can be removed is offered")
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
