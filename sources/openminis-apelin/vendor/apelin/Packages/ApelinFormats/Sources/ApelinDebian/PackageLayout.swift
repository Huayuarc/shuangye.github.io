import Foundation

/// The two bootstrap layouts a package is built for.
public enum BootstrapFlavor: String, Sendable, Hashable, CaseIterable, Codable {
    /// Everything under the fixed `/var/jb`, architecture `iphoneos-arm64`.
    case rootless
    /// Paths spelled from `/` inside a jbroot the bootstrap picks at boot,
    /// architecture `iphoneos-arm64e`.
    case roothide
}

/// Where a logical path lands inside a package built for one flavor, and the
/// fields that go with it.
///
/// A *logical* path is what a project or template names: `/Applications/X.app`,
/// `/Library/MobileSubstrate/DynamicLibraries/X.dylib`, `/usr/bin/x`. A
/// *package* path is what the `data.tar` holds. The rules mirror
/// `Scripts/package-deb.sh` and the Makefile's `FLAVOR` table:
///
/// | flavor   | package prefix | Architecture      | `@ROOTFS@` |
/// |----------|----------------|-------------------|------------|
/// | rootless | `/var/jb`      | `iphoneos-arm64`  | (empty)    |
/// | roothide | (none)         | `iphoneos-arm64e` | `/rootfs`  |
///
/// The `/var/jb` here is part of the rootless *package format* — the paths a
/// rootless `.deb` must spell — and never the runtime install root. Which
/// flavor to build for, and where the bootstrap actually is, comes from
/// apelind's `hello`; nothing here guesses either.
public struct PackageLayout: Sendable, Hashable {
    public let flavor: BootstrapFlavor

    public init(flavor: BootstrapFlavor) {
        self.flavor = flavor
    }

    public static let rootless = PackageLayout(flavor: .rootless)
    public static let roothide = PackageLayout(flavor: .roothide)

    /// The layout a control file's `Architecture` names, or nil for any other
    /// architecture (`iphoneos-arm`, `all`, ...).
    public init?(architecture: String) {
        guard let flavor = BootstrapFlavor.allCases.first(where: { PackageLayout(flavor: $0).architecture == architecture })
        else { return nil }
        self.flavor = flavor
    }

    /// What `@PREFIX@` becomes and what every package path starts with:
    /// `/var/jb` for rootless, empty for roothide.
    public var installPrefix: String {
        switch flavor {
        case .rootless: "/var/jb"
        case .roothide: ""
        }
    }

    /// The control file's `Architecture`.
    public var architecture: String {
        switch flavor {
        case .rootless: "iphoneos-arm64"
        case .roothide: "iphoneos-arm64e"
        }
    }

    /// What `@ROOTFS@` becomes: roothide's launchctl strips `/rootfs` off a
    /// launchd path to reach the system; rootless's passes paths through.
    public var rootfsPrefix: String {
        switch flavor {
        case .rootless: ""
        case .roothide: "/rootfs"
        }
    }

    /// The package path for a logical one: `/Applications/X.app` becomes
    /// `/var/jb/Applications/X.app` for rootless and stays as it is for
    /// roothide.
    ///
    /// The logical path must be canonical and absolute, and must not already
    /// carry a bootstrap prefix (`/var/jb`, `/rootfs`): a path prefixed twice
    /// installs somewhere nobody looks.
    public func packagePath(for logicalPath: String) throws -> String {
        let components = try PackagePath.components(ofAbsolute: logicalPath)
        if components.starts(with: ["var", "jb"]) || components.first == "rootfs" {
            throw PackageFormatError.invalidPath("\(logicalPath) already carries a bootstrap prefix")
        }
        if components.isEmpty {
            return installPrefix.isEmpty ? "/" : installPrefix
        }
        return installPrefix + "/" + components.joined(separator: "/")
    }

    /// The logical path for a package path, or `invalidPath` when the package
    /// path is outside this layout's prefix.
    public func logicalPath(forPackagePath packagePath: String) throws -> String {
        let components = try PackagePath.components(ofAbsolute: packagePath)
        let prefix = try PackagePath.components(ofAbsolute: installPrefix.isEmpty ? "/" : installPrefix)
        guard components.starts(with: prefix) else {
            throw PackageFormatError.invalidPath("\(packagePath) is outside \(flavor.rawValue)'s prefix")
        }
        return "/" + components.dropFirst(prefix.count).joined(separator: "/")
    }

    // MARK: - The product kinds

    /// `/Applications/<name>.app`, as a package path.
    public func applicationBundle(named name: String) throws -> String {
        try packagePath(for: "/Applications/" + component(name, suffix: ".app"))
    }

    /// `/Library/MobileSubstrate/DynamicLibraries/<name>.dylib`, the path
    /// every injection framework still reads, as a package path.
    public func tweakLibrary(named name: String) throws -> String {
        try packagePath(for: "/Library/MobileSubstrate/DynamicLibraries/" + component(name, suffix: ".dylib"))
    }

    /// The filter beside a tweak library: `<name>.plist` in the same folder.
    public func tweakFilter(named name: String) throws -> String {
        try packagePath(for: "/Library/MobileSubstrate/DynamicLibraries/" + component(name, suffix: ".plist"))
    }

    /// `/usr/bin/<name>`, as a package path.
    public func commandLineTool(named name: String) throws -> String {
        try packagePath(for: "/usr/bin/" + component(name, suffix: ""))
    }

    /// `/Library/PreferenceBundles/<name>.bundle`, as a package path.
    public func preferenceBundle(named name: String) throws -> String {
        try packagePath(for: "/Library/PreferenceBundles/" + component(name, suffix: ".bundle"))
    }

    /// `/Library/PreferenceLoader/Preferences/<name>.plist`, the entry that
    /// puts a preference bundle into Settings, as a package path.
    public func preferenceLoaderEntry(named name: String) throws -> String {
        try packagePath(for: "/Library/PreferenceLoader/Preferences/" + component(name, suffix: ".plist"))
    }

    /// `text` with `@PREFIX@` and `@ROOTFS@` replaced, as the packager does
    /// for launchd plists and maintainer scripts.
    public func substitutingPlaceholders(in text: String) -> String {
        text.replacingOccurrences(of: "@PREFIX@", with: installPrefix)
            .replacingOccurrences(of: "@ROOTFS@", with: rootfsPrefix)
    }

    /// `name` with `suffix` added unless it already ends in it, refused when
    /// it is not a single path component.
    private func component(_ name: String, suffix: String) throws -> String {
        let full = suffix.isEmpty || name.hasSuffix(suffix) ? name : name + suffix
        guard PackagePath.isValidComponent(name), full != suffix else {
            throw PackageFormatError.invalidPath(name.debugDescription)
        }
        return full
    }
}
