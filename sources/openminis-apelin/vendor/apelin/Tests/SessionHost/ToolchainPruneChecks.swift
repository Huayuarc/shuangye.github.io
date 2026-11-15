import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// The folders a removed toolchain package leaves on roothide, each with the
// `.jbroot` link roothide adds and no package lists
// (Apelind/Session/Install/ToolchainTreePruner.swift): such a skeleton goes,
// after a removal and at start for a package dpkg no longer lists; a file,
// another link, a link in place of a folder or a name that is not one folder
// keeps everything as it was.

/// `folders` under `<toolchains>/<id>`, each with a `.jbroot` link to `link`,
/// as roothide's removal leaves a toolchain.
func makeToolchainSkeleton(_ toolchains: String, _ id: String, folders: [String], link: String) {
    let tree = toolchains + "/" + id
    for folder in [""] + folders {
        let path = folder.isEmpty ? tree : tree + "/" + folder
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        symlink(link, path + "/.jbroot")
    }
}

/// Whether anything is at `path`, a link included, without following it.
func entryExists(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
}

func toolchainPruneChecks() async throws {
    let base = scratchPath + "/toolchain-prune"
    let root = base + "/jbroot"
    let toolchains = ToolchainTreePruner.folder(installRoot: root)
    // What every `.jbroot` names: the bootstrap's root, with a file of its own.
    let outside = base + "/outside"
    write(outside + "/kept", "kept\n")
    let folders = ["usr", "usr/bin", "usr/lib", "usr/lib/clang/27/include"]
    func links(_ id: String) -> Bool {
        ([""] + folders).allSatisfy {
            entryExists(toolchains + "/" + id + ($0.isEmpty ? "" : "/" + $0) + "/.jbroot")
        }
    }
    func isKept(_ outcome: ToolchainTreePruner.Outcome) -> Bool {
        if case .kept = outcome {
            return true
        }
        return false
    }

    makeToolchainSkeleton(toolchains, "skeleton", folders: folders, link: outside)
    makeToolchainSkeleton(toolchains, "sibling", folders: folders, link: outside)
    let pruned = ToolchainTreePruner.prune(installRoot: root, id: "skeleton")
    check(pruned == .pruned, "prune: a tree of folders and .jbroot links goes (\(pruned))")
    check(!entryExists(toolchains + "/skeleton"), "prune: the toolchain's own folder goes too")
    check(entryExists(toolchains), "prune: the toolchains folder stays")
    check(entryExists(outside + "/kept"), "prune: a .jbroot link is unlinked, never followed")
    check(links("sibling"), "prune: a sibling toolchain is untouched")
    check(ToolchainTreePruner.prune(installRoot: root, id: "skeleton") == .absent, "prune: a toolchain with no folder is absent")

    makeToolchainSkeleton(toolchains, "with-file", folders: folders, link: outside)
    write(toolchains + "/with-file/usr/lib/clang/27/include/stddef.h", "// left\n")
    check(isKept(ToolchainTreePruner.prune(installRoot: root, id: "with-file")), "prune: a file deep down keeps the tree")
    check(links("with-file"), "prune: and every .jbroot link in it")

    makeToolchainSkeleton(toolchains, "with-link", folders: folders, link: outside)
    symlink("clang", toolchains + "/with-link/usr/bin/cc")
    check(isKept(ToolchainTreePruner.prune(installRoot: root, id: "with-link")), "prune: a link other than .jbroot keeps the tree")
    check(links("with-link") && entryExists(toolchains + "/with-link/usr/bin/cc"), "prune: and the link with it")

    makeToolchainSkeleton(toolchains, "file-link", folders: ["usr"], link: outside)
    unlink(toolchains + "/file-link/usr/.jbroot")
    write(toolchains + "/file-link/usr/.jbroot", "not a link\n")
    check(isKept(ToolchainTreePruner.prune(installRoot: root, id: "file-link")), "prune: a .jbroot that is a file keeps the tree")

    makeToolchainSkeleton(base, "elsewhere", folders: ["usr"], link: outside)
    symlink(base + "/elsewhere", toolchains + "/linked")
    check(isKept(ToolchainTreePruner.prune(installRoot: root, id: "linked")), "prune: a toolchain folder that is a link is kept")
    check(entryExists(base + "/elsewhere/usr/.jbroot"), "prune: and what it names is untouched")

    for id in ["..", ".", "", ".hidden", "a/b", "a\u{0}b", "UPPER"] {
        check(isKept(ToolchainTreePruner.prune(installRoot: root, id: id)), "prune: \(id.debugDescription) is not a toolchain's folder")
    }
    check(entryExists(root + "/usr/lib/apelin") && entryExists(toolchains + "/sibling"), "prune: nothing above the toolchains folder is reached")
    check(ToolchainTreePruner.toolchainID(packageID: ManagedPackagePolicy.toolchainPrefix + "a1b2") == "a1b2", "prune: a toolchain package names its folder")
    for package in ["com.example.hello", ManagedPackagePolicy.toolchainPrefix, ManagedPackagePolicy.toolchainPrefix + ".", ManagedPackagePolicy.toolchainPrefix + "..", "wiki.qaq.apelin"] {
        check(ToolchainTreePruner.toolchainID(packageID: package) == nil, "prune: \(package) names no toolchain folder")
    }

    // The toolchains folder itself a link out of the install root.
    let otherRoot = base + "/other-root"
    try FileManager.default.createDirectory(atPath: otherRoot + "/usr/lib/apelin", withIntermediateDirectories: true)
    makeToolchainSkeleton(base + "/foreign", "skeleton", folders: ["usr"], link: outside)
    symlink(base + "/foreign", otherRoot + "/usr/lib/apelin/toolchains")
    check(isKept(ToolchainTreePruner.prune(installRoot: otherRoot, id: "skeleton")), "prune: a toolchains folder leading out of the install root is refused")
    check(entryExists(base + "/foreign/skeleton/usr/.jbroot"), "prune: and what it leads to is untouched")
    check(ToolchainTreePruner.toolchainIDs(installRoot: otherRoot).isEmpty, "prune: nor listed")

    // At start, by dpkg's own list: a package it lists in any state but not
    // installed keeps its folders, and so does one an install or removal
    // still handles.
    let sweep = base + "/sweep"
    let sweepToolchains = ToolchainTreePruner.folder(installRoot: sweep)
    let prefix = ManagedPackagePolicy.toolchainPrefix
    write(sweep + "/var/lib/dpkg/status", """
    Package: \(prefix)installed
    Status: install ok installed
    Version: 1

    Package: \(prefix)purged
    Status: purge ok not-installed

    Package: \(prefix)unpacking
    Status: install ok half-installed
    Version: 1

    """)
    let names = ["installed", "purged", "unpacking", "gone", "submitted", "with-file"]
    for name in names {
        makeToolchainSkeleton(sweepToolchains, name, folders: ["usr", "usr/bin"], link: outside)
    }
    makeToolchainSkeleton(sweepToolchains, ".hidden", folders: ["usr"], link: outside)
    write(sweepToolchains + "/with-file/usr/bin/clang", "")
    let state = URL(fileURLWithPath: base + "/sweep-state")
    let installations = InstallationStore(directory: state.appendingPathComponent("installations"))
    try await installations.save(record(package: prefix + "submitted", version: "1", status: .submitted))
    let registry = TaskRegistry(directory: state.appendingPathComponent("tasks"))
    await registry.load()
    func bridge(_ packages: InstalledPackageSource) -> InstallBridge {
        InstallBridge(
            paths: .init(installRoot: sweep, dataFolder: base, staging: state.appendingPathComponent("staging")),
            service: FakeIrisin(root: sweep),
            registry: registry,
            artifacts: ArtifactRegistry(file: state.appendingPathComponent("artifacts.json")),
            installations: installations,
            packages: packages,
            fileLists: FakeFileLists(),
            approvals: ApprovalLedger(directory: state.appendingPathComponent("approvals")),
        )
    }
    await bridge(DpkgStatusDatabase(installRoot: base + "/no-dpkg")).pruneLeftoverToolchains()
    check(names.allSatisfy { entryExists(sweepToolchains + "/" + $0) }, "sweep: without dpkg's list nothing goes")
    await bridge(DpkgStatusDatabase(installRoot: sweep)).pruneLeftoverToolchains()
    let left = names.filter { entryExists(sweepToolchains + "/" + $0) }
    check(left == ["installed", "unpacking", "submitted", "with-file"], "sweep: only the skeletons of packages that are gone and unhandled go (\(left))")
    check(entryExists(sweepToolchains + "/.hidden/.jbroot"), "sweep: a folder that is no toolchain's stays")
    check(entryExists(outside + "/kept"), "sweep: what the links name stays")
}
