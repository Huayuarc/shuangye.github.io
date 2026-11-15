import ApelinCore
import ApelinProtocol
import SPIndicator
import UIKit

/// Sharing and publishing release packages, from the distribution page and
/// the build page alike. Each package is the file its build made, read back
/// against the digest the build recorded first: nothing is built or
/// packaged again.
@MainActor
enum DistributionPublishing {
    /// A package's file and the digest its build recorded.
    struct Item {
        var path: String?
        var digest: String
        /// The line a confirmation names it by.
        var title: String

        init(path: String?, digest: String, packageID: String, version: String, bootstrap: BuildBootstrap) {
            self.path = path
            self.digest = digest
            title = "\(packageID) \(version) (\(bootstrap.rawValue))"
        }
    }

    /// The share sheet with the package, pointing at `anchor`; a share that
    /// completes makes it Shared (`SharedPackages`) and calls `onShared`.
    static func share(
        _ item: Item,
        from presenter: UIViewController,
        anchor: any UIPopoverPresentationControllerSourceItem,
        onShared: @escaping () -> Void = {},
    ) async {
        do {
            let file = try await Task.detached {
                try DistributionPackages.verify(path: item.path, digest: item.digest)
            }.value
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = anchor
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                guard completed else { return }
                SharedPackages.record(item.digest)
                onShared()
            }
            presenter.present(sheet, animated: true)
        } catch {
            presenter.presentNotice(title: "Unable to Share", message: error.readableMessage)
        }
    }

    /// The packages into the linked package repository in one commit: read
    /// back, named with the repository in a confirmation, then followed as
    /// a task on `presenter`'s navigation. A package the repository already
    /// holds with the same bytes is skipped, and one it holds with other
    /// bytes refused (`distributionPublish`). With no repository linked,
    /// Settings ▸ Git instead.
    static func publish(_ items: [Item], from presenter: UIViewController) async {
        do {
            guard let linked = try await ApelinService.app.distributionRepositoryList(repositories: false).linked else {
                openRepositorySetup(from: presenter)
                return
            }
            let files = try await Task.detached { () throws -> [(path: String, digest: String)] in
                try items.map { item -> (path: String, digest: String) in
                    let file = try DistributionPackages.verify(path: item.path, digest: item.digest)
                    return (file.path, item.digest)
                }
            }.value
            let packages = items.map(\.title).joined(separator: "\n")
            presenter.presentConfirmation(
                title: "Publish to \(linked.fullName)?",
                message: "\(packages)\n\nEach package goes into the repository’s debs folder as it was built, in one commit that is pushed. Devices with \(linked.sourceURL) see the update within a few minutes.",
                confirmTitle: "Publish",
            ) { [weak presenter] in
                guard let presenter else { return }
                start(files, to: linked.fullName, from: presenter)
            }
        } catch {
            presenter.presentNotice(title: "Unable to Publish", message: error.readableMessage)
        }
    }

    /// `files`, read back already, each with the digest its build recorded,
    /// which apelin-environment checks the bytes against again before any
    /// goes in; `repository` is the one the confirmation named, so a link
    /// changed meanwhile publishes nothing.
    private static func start(
        _ files: [(path: String, digest: String)],
        to repository: String,
        from presenter: UIViewController,
    ) {
        Task { [weak presenter] in
            do {
                let handle = try await ApelinService.app.distributionPublish(
                    files: files.map(\.path),
                    digests: files.map(\.digest),
                    repository: repository,
                )
                let page = EnvironmentTaskController(
                    handle: handle,
                    work: .distributionPublish,
                    title: String(localized: "Publishing Package"),
                    doneTitle: String(localized: "Published"),
                )
                presenter?.navigationController?.pushViewController(page, animated: true)
            } catch {
                presenter?.presentNotice(title: "Unable to Publish", message: error.readableMessage)
            }
        }
    }

    /// Settings ▸ Git over `presenter`, which stays as it is: Publishing
    /// there creates or links a repository, after Sign In when GitHub has
    /// no account yet. The indicator says why it opened.
    private static func openRepositorySetup(from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        SPIndicator.present(title: String(localized: "No Package Repository"), preset: .error, haptic: .warning)
        SettingsViewController.presentGit(from: presenter)
    }
}
