import ApelinAgent
import ApelinCore
import ApelinProtocol
import CryptoKit
import Foundation

/// The agent's read of Confirm's build and install rule, from the session
/// host's private ledger: the description digest as apelin-build computes it
/// (`projectCheck` ▸ `descriptionDigests`), then `approvalDigestState` for
/// where it stands — the template's own (no prompt), approved before, or
/// changed (ask once; the host records the approval when it relays the
/// user's yes). The host enforces the same rule itself on every build and
/// install, so this only decides whether the agent asks first.
///
/// When apelin-build does not answer a digest, the agent falls back to its
/// own SHA-256 over `configurations`/`products`/`build` (build) or `package`
/// (packaging) with keys sorted; that never equals the template's, so the
/// call asks — erring toward asking, never past the host.
struct HostDigestLedger: ApprovalDigestStore {
    let service: ApelinService
    let projectURL: URL
    /// `~/Documents/wiki.qaq.apelin`, whose `Builds/artifacts/` apelin-build
    /// records each package in.
    let dataFolder: URL

    func state(of kind: DescriptionKind, for project: ApelinAgent.ProjectIdentity) async throws -> DescriptionState {
        let digest = try await hostDigest(kind, projectID: project.id) ?? Self.digest(of: kind, projectURL: projectURL)
        let wireKind: ApprovalDescriptionKind = kind == .build ? .build : .packaging
        let answer = try? await service.approvalDigestState(projectID: project.id, kind: wireKind, digest: digest)
        switch answer?.baseline {
        case .matchesTemplate?:
            return DescriptionState(digest: digest, baseline: .matchesTemplate)
        case .approved?:
            return DescriptionState(digest: digest, baseline: .approved)
        case .changed?, nil:
            let against = answer?.lastApprovedDigest.map { "the last approved \($0)" }
                ?? answer?.templateDigest.map { "the template's \($0)" }
                ?? "no recorded baseline"
            return DescriptionState(
                digest: digest,
                baseline: .changed(
                    diff: "The \(kind.rawValue) description is \(digest), not \(against); review apelin-project.json.",
                ),
            )
        }
    }

    /// A workspace's package: the packaging digest apelin-build recorded
    /// for it (`Builds/artifacts/<id>.json`), then where it stands. The host
    /// judges the install by the digest it recorded from the build's own
    /// event, so a record changed since only makes the agent ask.
    func packagingState(ofArtifact artifactID: String, for project: ApelinAgent.ProjectIdentity) async throws -> DescriptionState? {
        guard !artifactID.isEmpty, artifactID.count <= 128,
              artifactID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        let url = dataFolder.appendingPathComponent("Builds/artifacts/\(artifactID).json")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let record = try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data),
              record["projectID"]?.stringValue == project.id,
              let digest = record["packagingDigest"]?.stringValue
        else { return nil }
        let answer = try? await service.approvalDigestState(projectID: project.id, kind: .packaging, digest: digest)
        switch answer?.baseline {
        case .matchesTemplate?:
            return DescriptionState(digest: digest, baseline: .matchesTemplate)
        case .approved?:
            return DescriptionState(digest: digest, baseline: .approved)
        case .changed?, nil:
            return DescriptionState(
                digest: digest,
                baseline: .changed(
                    diff: "This package's control file, maintainer scripts or installed paths are \(digest), which you have not approved for this workspace; review the package before it is installed.",
                ),
            )
        }
    }

    /// `descriptionDigests.<kind>` from apelin-build's `projectCheck`.
    func hostDigest(_ kind: DescriptionKind, projectID: String) async -> String? {
        guard let digests = try? await service.projectCheck(projectID: projectID).descriptionDigests else { return nil }
        return kind == .build ? digests.build : digests.packaging
    }

    static func digest(of kind: DescriptionKind, projectURL: URL) throws -> String {
        let url = projectURL.appendingPathComponent("apelin-project.json")
        let data = try Data(contentsOf: url)
        guard data.count <= 1 << 20 else { throw CocoaError(.fileReadTooLarge) }
        let manifest = try JSONCoding.decode(ApelinCore.JSONValue.self, from: data)
        let keys = kind == .build ? ["configurations", "products", "build"] : ["package"]
        var subset: [String: ApelinCore.JSONValue] = [:]
        for key in keys {
            subset[key] = manifest[key] ?? .null
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(ApelinCore.JSONValue.object(subset))
        return "sha256:" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
