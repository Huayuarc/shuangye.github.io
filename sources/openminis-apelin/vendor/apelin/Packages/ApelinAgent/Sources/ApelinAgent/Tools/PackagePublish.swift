import enum ApelinProject.ConfigurationName
import struct ApelinProtocol.DistributionPublishRequest
import Foundation
import KWWKAI

/// apelin_package_publish (owner, 2026-10-29): release builds' packages
/// put in the user's package repository as their builds made them, every
/// one in one commit — roothide and rootless of one version together. What could
/// never be published is refused here, before anyone is asked: a build
/// that left no package, a debug build, a package gone from Apelin's build
/// folder, two packages of one ID, version and architecture, and a device
/// with no linked repository or no GitHub sign-in. The card then names the
/// repository and each package with the digest its build recorded, and
/// apelin-environment publishes nothing unless every file still has it.
public enum PackagePublish {
    static let buildIDsKey = "build_ids"

    /// The builds the call names, each once.
    static func buildIDs(_ arguments: JSONValue) throws -> [String] {
        guard let ids = arguments.argStrings(buildIDsKey)?.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !ids.isEmpty, !ids.contains(where: \.isEmpty)
        else {
            throw ToolArgumentError("Nothing was published: name the build_id of each release build to publish, as apelin_project_build answered it.")
        }
        guard ids.count <= DistributionPublishRequest.maximumFiles else {
            throw ToolArgumentError("Nothing was published: publish at most \(DistributionPublishRequest.maximumFiles) packages at a time.")
        }
        var seen: Set<String> = []
        for id in ids {
            guard seen.insert(id).inserted else {
                throw ToolArgumentError("Nothing was published: \(id) is named twice.")
            }
        }
        return ids
    }

    /// What the card names, from what `publication` read of the builds
    /// `ids` names, in their order; every problem at once, else.
    static func approval(for ids: [String], publication: PackagePublication) throws -> PackagePublishApproval {
        guard publication.builds.count == ids.count else {
            throw ToolDeniedError(message: "Nothing was published: the builds' package records could not be read.")
        }
        var problems: [String] = []
        var packages: [PackagePublishApproval.Package] = []
        for (id, record) in zip(ids, publication.builds) {
            guard let record else {
                problems.append("No build \(id) made a package: give the build_id apelin_project_build answered, which is also its package artifact's id.")
                continue
            }
            let package = "\(record.packageID) \(record.version) for \(record.architecture)"
            // The record spells it as the project's configurations do
            // (issue #21: a lowercase comparison refused every release build).
            guard record.configuration == ConfigurationName.release.rawValue else {
                problems.append("\(id) is a \(record.configuration) build of \(package); publish a release build, made by apelin_project_build with configuration release and the bootstrap, once for roothide and once for rootless.")
                continue
            }
            guard record.present else {
                problems.append("The package of \(id), \(package), is no longer in Apelin's build folder: build it again.")
                continue
            }
            if let twin = packages.first(where: {
                $0.packageID == record.packageID && $0.version == record.version && $0.architecture == record.architecture
            }) {
                problems.append("\(twin.buildID) and \(id) are both \(package): publish one of them.")
                continue
            }
            packages.append(PackagePublishApproval.Package(
                buildID: record.buildID,
                packageID: record.packageID,
                version: record.version,
                architecture: record.architecture,
                bootstrap: record.bootstrap,
                file: record.file,
                digest: record.digest,
            ))
        }
        guard problems.isEmpty else {
            throw ToolArgumentError("Nothing was published. " + problems.joined(separator: " "))
        }
        guard let repository = publication.repository else {
            throw ToolDeniedError(message: Self.noRepository)
        }
        guard publication.signedIn != false else {
            throw ToolDeniedError(message: Self.signInNeeded)
        }
        return PackagePublishApproval(repository: repository.fullName, sourceURL: repository.sourceURL, packages: packages)
    }

    /// What the model hears without a linked repository, here and from the
    /// host's own refusal.
    public static let noRepository = "Nothing was published: no package repository is linked. Ask the user to create or link one in Settings ▸ Git ▸ Publishing, then publish again."

    /// What the model hears without a GitHub sign-in, or with one GitHub
    /// refused.
    public static let signInNeeded = "Nothing was published: GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then publish again."
}
