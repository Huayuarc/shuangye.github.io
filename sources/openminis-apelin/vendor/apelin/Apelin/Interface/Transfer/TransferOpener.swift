import ApelinCore
import ApelinProtocol
import Darwin
import UIKit
import UniformTypeIdentifiers

/// A transfer file the app was handed, held open: Open in Apelin, a file
/// picked in Files. The path is read once, to open it; from then on only the
/// descriptor is passed on, a duplicate for each request, and the file
/// closes when the last page holding it goes.
final class TransferFile {
    let descriptor: OwnedDescriptor
    /// The name it came with: the worker checks its extension against the
    /// manifest's kind.
    let fileName: String
    /// The kind its extension says.
    let kind: TransferKind

    init(descriptor: OwnedDescriptor, fileName: String, kind: TransferKind) {
        self.descriptor = descriptor
        self.fileName = fileName
        self.kind = kind
    }

    /// A descriptor for one request, which takes it.
    func duplicate() -> OwnedDescriptor? {
        OwnedDescriptor.duplicating(descriptor.rawValue)
    }
}

/// Opening a transfer file: the scene's Open in Apelin and the pickers in
/// Settings come here. The file is opened while its security scope lasts and
/// held by descriptor; the confirmation page (`TransferImportController`)
/// reads its manifest and asks before anything is imported.
@MainActor
enum TransferOpener {
    /// Posted once an import ended, so the Settings lists read themselves again.
    static let environmentChanged = Notification.Name("wiki.qaq.apelin.transferImported")

    static func contentType(_ kind: TransferKind) -> UTType {
        UTType(kind.typeIdentifier) ?? UTType(filenameExtension: kind.fileExtension) ?? .data
    }

    /// Open in Apelin: in front of whatever the scene shows.
    static func open(_ url: URL, in scene: UIWindowScene) {
        guard var top = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        open(url, from: top)
    }

    /// From a picker: pushed onto `navigation` when the picker's page is in
    /// one already (Settings is a sheet), else as a sheet of its own.
    static func open(
        _ url: URL,
        from presenter: UIViewController,
        pushingOnto navigation: UINavigationController? = nil,
    ) {
        let file: TransferFile
        switch Self.file(at: url) {
        case let .success(opened):
            file = opened
        case let .failure(problem):
            switch problem {
            case .unknownKind:
                presenter.presentNotice(
                    title: "Not an Apelin File",
                    message: "Apelin opens toolchains (.apetc), SDKs (.apesdk) and projects (.apeproj).",
                )
            case let .unreadable(reason):
                presenter.presentNotice(title: "Unable to Open", message: reason)
            }
            return
        }
        let page = TransferImportController(file: file)
        if let navigation {
            navigation.pushViewController(page, animated: true)
        } else {
            presenter.presentPageAsFormSheet(page)
        }
    }

    enum Problem: Error {
        case unknownKind
        case unreadable(String)
    }

    /// Opens the file read-only while its security scope lasts. Only a
    /// regular file of one of the three kinds is taken.
    static func file(at url: URL) -> Result<TransferFile, Problem> {
        let fileName = url.lastPathComponent
        guard let kind = TransferKind(fileName: fileName) else { return .failure(.unknownKind) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            return .failure(.unreadable(String(localized: "Unable to read the file: \(reason)")))
        }
        let owned = OwnedDescriptor(adopting: descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            return .failure(.unreadable(
                String(localized: "This item is not a file. Choose a toolchain, SDK or project file."),
            ))
        }
        return .success(TransferFile(descriptor: owned, fileName: fileName, kind: kind))
    }
}
