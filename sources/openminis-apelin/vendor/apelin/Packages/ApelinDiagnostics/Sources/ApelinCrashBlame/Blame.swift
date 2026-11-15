// Ported from Xrash (XrashKit/Sources/XrashBlame/Blame.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

import ApelinCrashReport
import Foundation

public struct PackageOwner: Codable, Hashable, Sendable {
    /// `com.example.tweak`.
    public var identifier: String
    public var name: String?
    public var version: String?
    /// `Jane Doe <jane@example.com>`, as the status file spells it.
    public var maintainer: String?
    public var installed: Date?

    public init(identifier: String) {
        self.identifier = identifier
    }

    /// The address to write to, out of `Jane Doe <jane@example.com>`; the last
    /// bracketed address wins, and a field without brackets is the address
    /// itself. A status file is a file on disk, so the candidate is checked
    /// rather than trusted: one address, no display name, and nothing that
    /// could carry a second recipient or a header of its own.
    public var maintainerAddress: String? {
        guard let maintainer else { return nil }
        let bracketed = maintainer.split(separator: "<").dropFirst().compactMap { part in
            part.firstIndex(of: ">").map { String(part[..<$0]) }
        }
        let candidate = bracketed.last { $0.contains("@") }
            ?? maintainer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("@"), candidate.rangeOfCharacter(from: Self.notInAnAddress) == nil else {
            return nil
        }
        return candidate
    }

    private static let notInAnAddress = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: ",;<>"))
}

/// Who installed the file at a path. Apelin replaces Xrash's `DpkgDatabase`
/// (a reader of `<root>/var/lib/dpkg/info`) with this: the product keeps no
/// coupling to dpkg's files, and the session host already knows which files
/// each package it installed carries. Whatever answers must be cheap per call
/// — `Blame` asks once per non-Apple image.
public protocol PackageOwnerLookup: Sendable {
    func owner(ofPath path: String) -> PackageOwner?
}

/// The spellings a report's image path and an installer's file list may use
/// for one file, from Xrash's `DpkgDatabase`. A report spells an image path
/// the way dyld loaded it and an installer spells it the way the bootstrap
/// installed it, so neither side is canonical and every form is tried.
public enum PackageOwnerPaths {
    /// The forms a file list might hold this path in. Rootless lists carry
    /// the `/var/jb` symlink and roothide and rootful ones are prefix-relative,
    /// while the path in the report may be either spelling and may or may not
    /// have come through `/private`. `installRoot` is what the daemon's
    /// `hello` reported.
    public static func spellings(of path: String, installRoot: String?) -> [String] {
        let root = installRoot.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var spellings = [String]()
        func add(_ spelling: String) {
            guard spelling.hasPrefix("/"), !spellings.contains(spelling) else { return }
            spellings.append(spelling)
        }
        for form in [path, throughPrivate(path)].compactMap(\.self) {
            add(form)
            if let root, root != "/", form.hasPrefix(root) {
                let relative = String(form.dropFirst(root.count))
                add(relative)
                add(rootlessPrefix + relative)
            }
            if form.hasPrefix(rootlessPrefix + "/") {
                add(String(form.dropFirst(rootlessPrefix.count)))
            }
        }
        return spellings
    }

    /// Where a rootless bootstrap is reached from, as dyld records it.
    private static let rootlessPrefix = "/var/jb"

    /// The same file said the other way round: `/var/x` and `/private/var/x`
    /// are one path, and only one of them matches an install root that has
    /// been through `realpath(3)`.
    private static func throughPrivate(_ path: String) -> String? {
        if path.hasPrefix("/private/") {
            return String(path.dropFirst("/private".count))
        }
        return ["/var/", "/etc/", "/tmp/"].contains(where: path.hasPrefix) ? "/private" + path : nil
    }
}

/// A fixed map of installed file → owning package, as the session host's
/// installation records hold it (paths as the package lists them, relative to
/// the install root or absolute). Every spelling of the asked path is tried.
public struct StaticPackageOwners: PackageOwnerLookup {
    private let ownerByPath: [String: PackageOwner]
    private let installRoot: String?

    public init(ownerByPath: [String: PackageOwner], installRoot: String?) {
        self.ownerByPath = ownerByPath
        self.installRoot = installRoot
    }

    public func owner(ofPath path: String) -> PackageOwner? {
        for spelling in PackageOwnerPaths.spellings(of: path, installRoot: installRoot) {
            if let owner = ownerByPath[spelling] {
                return owner
            }
        }
        return nil
    }
}

public struct Suspect: Codable, Hashable, Sendable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        /// Appears on the faulting thread's stack.
        case onFaultingStack
        /// Appears in the last exception backtrace.
        case inExceptionBacktrace
        /// Loaded from a tweak injection directory.
        case injectedTweak
        /// Not Apple's and not the crashed app's own.
        case thirdPartyImage
        /// Installed or updated shortly before the crash.
        case recentlyInstalled
    }

    /// The image path.
    public var id: String
    public var imageName: String
    public var reasons: [Reason]
    public var owner: PackageOwner?
    /// Higher is more likely; only meaningful for ordering.
    public var score: Int

    public init(id: String, imageName: String, reasons: [Reason], owner: PackageOwner?, score: Int) {
        self.id = id
        self.imageName = imageName
        self.reasons = reasons
        self.owner = owner
        self.score = score
    }
}

public enum Blame {}
