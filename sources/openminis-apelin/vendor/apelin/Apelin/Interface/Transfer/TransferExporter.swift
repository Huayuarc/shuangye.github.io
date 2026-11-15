import ApelinCore
import ApelinProtocol
import UIKit

/// Export…: a toolchain or an SDK written into a transfer file by the
/// session host (`transferExport`), followed on Fila's progress card, then
/// handed to the share sheet — AirDrop, Files, a chat app. The file lives in
/// `Exports/<kind>-<id>/` in the data folder until it has been shared, and
/// goes once a share completes; a later export of the same item replaces it.
@MainActor
enum TransferExporter {
    /// Asks once — what the file holds, and that it is for the user's own
    /// devices — then exports and shares it from `anchor`.
    static func confirmAndExport(
        kind: TransferKind,
        id: String,
        name: String,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
    ) {
        presentConfirmation(on: presenter, kind: kind) { [weak presenter, weak anchor] in
            guard let presenter, let anchor else { return }
            export(kind: kind, id: id, name: name, from: presenter, anchor: anchor)
        }
    }

    // One literal per kind: AlertController looks the key up in the catalogue.

    private static func presentConfirmation(
        on presenter: UIViewController,
        kind: TransferKind,
        start: @escaping () -> Void,
    ) {
        switch kind {
        case .toolchain:
            presenter.presentConfirmation(
                title: "Export the Toolchain?",
                message: "This file contains Apple’s Command Line Tools adapted for your own devices. Apelin does not upload it.",
                confirmTitle: "Export",
                onConfirm: start,
            )
        case .sdk:
            presenter.presentConfirmation(
                title: "Export the SDK?",
                message: "This file contains Apple’s iPhoneOS SDK for your own devices. Apelin does not upload it.",
                confirmTitle: "Export",
                onConfirm: start,
            )
        case .project:
            presenter.presentConfirmation(
                title: "Export the Project?",
                message: "Includes project files and Git history, if available. Files ignored by Git are excluded.",
                confirmTitle: "Export",
                onConfirm: start,
            )
        }
    }

    /// `Apelin <version> (<build>)`, for the manifest.
    static var createdBy: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Apelin \(version) (\(build))"
    }

    private static func export(
        kind: TransferKind,
        id: String,
        name: String,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
    ) {
        Task { [weak presenter] in
            guard let presenter else { return }
            do {
                let export = try await ProgressCard.run(
                    title: title(kind),
                    message: name,
                    cancellable: true,
                    from: presenter,
                ) { update in
                    try await run(kind: kind, id: id, update: update)
                }
                share(export, from: presenter, anchor: anchor)
            } catch is CancellationError {
                // stopped from the card; the host cleans its own staging
            } catch {
                presenter.presentNotice(title: "Unable to Export", message: error.readableMessage)
            }
        }
    }

    private static func title(_ kind: TransferKind) -> String {
        switch kind {
        case .toolchain: String(localized: "Exporting Toolchain…")
        case .sdk: String(localized: "Exporting SDK…")
        case .project: String(localized: "Exporting Project…")
        }
    }

    /// Starts the export and reads it to its end; a cancel of the card
    /// stops the host's task too.
    private static func run(
        kind: TransferKind,
        id: String,
        update: @escaping @MainActor (ProgressCard.Status) -> Void,
    ) async throws -> TransferExport {
        let handle = try await ApelinService.app.transferExport(kind: kind, id: id, createdBy: createdBy)
        var progress = EnvironmentTaskProgress(work: .transferExport)
        var export: TransferExport?
        try await withTaskCancellationHandler {
            for try await event in ApelinService.app.events(of: handle) {
                progress.apply(event)
                if event.kind == "result", let value = event.payload?["export"] {
                    export = try? value.decode(TransferExport.self)
                }
                update(status(of: progress))
            }
        } onCancel: {
            Task { try? await ApelinService.app.environmentCancel(taskID: handle.taskID) }
        }
        try Task.checkCancellation()
        guard progress.state == .succeeded, let export else {
            throw ApelinError(.internal, progress.outcomeMessage)
        }
        return export
    }

    /// "Writing File…" over "120 MB of 480 MB" and the bar.
    private static func status(of progress: EnvironmentTaskProgress) -> ProgressCard.Status {
        let stage = progress.stage.map(EnvironmentTaskProgress.activeTitle(of:)) ?? ""
        if progress.stage == "collecting" {
            return ProgressCard.Status(subtitle: stage, count: String(localized: "\(progress.completed) items checked"))
        }
        guard progress.countsBytes else {
            return ProgressCard.Status(subtitle: stage, fraction: progress.fraction)
        }
        let done = ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)
        let count = progress.total.map {
            String(localized: "\(done) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))")
        } ?? done
        return ProgressCard.Status(subtitle: stage, fraction: progress.fraction, count: count)
    }

    private static func share(_ export: TransferExport, from presenter: UIViewController, anchor: UIBarButtonItem) {
        let url = URL(fileURLWithPath: export.path)
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = anchor
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            // shared or saved elsewhere: the copy here is not needed
            if completed {
                removeExport(at: url)
            }
        }
        presenter.present(sheet, animated: true)
    }

    /// Deletes `Exports/<kind>-<id>/`, and only a folder that is one level
    /// below the data folder's `Exports`.
    private static func removeExport(at file: URL) {
        let folder = file.deletingLastPathComponent()
        let exports = DataFolder.app.root.appendingPathComponent("Exports", isDirectory: true)
        guard let resolvedFolder = CanonicalPath.resolve(folder.path),
              let resolvedExports = CanonicalPath.resolve(exports.path),
              CanonicalPath.isCanonical(resolvedFolder, inside: resolvedExports),
              CanonicalPath.components(resolvedFolder).count == CanonicalPath.components(resolvedExports).count + 1
        else { return }
        try? FileManager.default.removeItem(atPath: resolvedFolder)
    }
}
