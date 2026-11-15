import Darwin
import Foundation

/// What apelin_package_install adds to an app project's result. Installing
/// replaces the bundle on disk, but a copy of the app already running keeps
/// the build it started with until it exits, and neither the installer nor
/// the host restarts it: on a device the agent went on testing the old
/// build, and icli's `app kill` refused it without `--force`.
enum AppRelaunch {
    private static let maximumInfoPlistBytes = 1 << 20

    /// The sentence for a project whose manifest's `kind` is `app`, naming
    /// the bundle id of its app product; nil for every other kind.
    static func hint(in root: ScopedRoot) -> String? {
        guard let manifest = ProjectBuildSystem.manifest(in: root), manifest["kind"] as? String == "app" else { return nil }
        guard let bundleID = bundleID(manifest, in: root) else {
            return "If the app is running, it still runs the previous build. To run this one, restart it through shell_run as mobile: icli app kill --force <bundle id>, then icli app launch <bundle id>, with the CFBundleIdentifier of the app's Info.plist (icli app list names it too)."
        }
        return "If \(bundleID) is running, it still runs the previous build. To run this one, restart it through shell_run as mobile: icli app kill --force \(bundleID), then icli app launch \(bundleID)."
    }

    /// `CFBundleIdentifier` of the first `app` product's Info.plist, read
    /// inside the project; nil when it does not read or is not spelled as a
    /// bundle id, since the file is the project's, whatever it holds.
    static func bundleID(_ manifest: [String: Any], in root: ScopedRoot) -> String? {
        let products = manifest["products"] as? [[String: Any]] ?? []
        guard let infoPlist = products.first(where: { $0["type"] as? String == "app" })?["infoPlist"] as? String,
              let path = try? root.resolveExisting(infoPlist),
              let data = read(path, limit: maximumInfoPlistBytes),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              (1 ... 255).contains(identifier.count), identifier.allSatisfy(bundleIDCharacters.contains)
        else { return nil }
        return identifier
    }

    /// What a bundle id is made of: ASCII letters and digits, `-` and `.`.
    private static let bundleIDCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")

    /// A regular file, not through a link, when it is no larger than `limit`.
    private static func read(_ path: String, limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= off_t(limit)
        else { return nil }
        return try? handle.read(upToCount: limit)
    }
}
