# ApelinFormats

The file formats Apelin reads and writes on the device: Mach-O images, and
Debian binary packages in both directions. Every API is synchronous and
throwing; nothing spawns a process, imports UIKit or knows where the
bootstrap is installed. iOS 16 and macOS 13; `swift test` runs everything on
a Mac.

| Product            | What it is                                                        | Dependencies |
|--------------------|-------------------------------------------------------------------|--------------|
| `ApelinMachO`      | Mach-O reader: fat/thin, slices, load commands, UUID, dylibs, segments, entitlements, signing identity | none |
| `ApelinDebian`     | Control paragraphs, Debian version order, the control file generator, bootstrap layouts | none |
| `ApelinDebArchive` | `.deb` reader and writer                                          | `ApelinDebian`, ArchiveKit (`Lakr233/libarchive.xcframework`) |
| `ApelinCodeSign`   | Ad-hoc signing as `ldid -Hsha256 -S[entitlements]` writes it, every slice | CryptoKit |

`ApelinMachO` and `ApelinDebian` have no dependencies, so a privileged
process may link them. `ApelinDebArchive` links libarchive and is never
linked into apelind.

## Where the code came from

- `ApelinMachO` is Fila's `FilaFormats/MachOImage` (MIT, OwnGoal Studio), the
  upstream of the fork in Xrash. Fila's inspector decodes segments and
  versions through p-x9/MachOKit; here those few fixed layouts are decoded by
  hand with Fila's bounds checks, so the module stays dependency-free.
- `DebianControl`, `DebianVersion` and their tests are Irisin's (MIT, OwnGoal
  Studio), unchanged, with the `dpkg --compare-versions` fixture.
- `DebArchiveReader` is Irisin's `ArchiveStream` debian readers plus the
  member checks of its package preparation, over the same libarchive package
  and version.
- `ApelinCodeSign` is Irisin's `LdidStyleSignature` and `LdidEntitlements`
  (MIT, OwnGoal Studio; `LICENSE` beside the sources) and the slice handling
  of its `MachOBinary`, read by hand instead of through MachOKit and without
  roothide's install-name rewrite. `Tests/ApelinCodeSignTests/Fixtures` holds
  inputs built from `fixture.c` and what `ldid -Hsha256 -S` made of them
  (`build.sh`); the signer must match them byte for byte. It is Apelin's one
  signer: `Packages/ApelinToolchain` builds its retargeted tools' signatures
  from the same `LdidStyleSignature` and `LdidEntitlements`, held to Irisin's
  seven device ldid fixtures there.
- The `.deb` writer is new. The tar and `ar` containers are written by hand,
  so every byte is decided here; libarchive only compresses.

## Reading a Mach-O

```swift
import ApelinMachO

let image = try MachOImage(contentsOfFile: path)   // or (descriptor:), (data:)
for slice in image.slices {
    print(slice.architecture, slice.uuid as Any, slice.installName as Any)
    print(slice.linkedLibraries)
    let inspection = try image.inspect(slice)
    print(inspection.platform?.name as Any, inspection.minimumOS as Any)
    print(inspection.segments.map(\.name), inspection.runpaths)
    let entitlements = try image.entitlementsDictionary(of: slice)
}
```

Only the header, the load-command region and the code directory's fixed
fields are read, never the whole file. Every length is checked against the
bytes present, and damage throws `FormatFailure` rather than trapping.

## Writing a package

```swift
import ApelinDebArchive
import ApelinDebian

let layout = PackageLayout.rootless          // decided by apelind's hello
var control = DebianControlFile(
    package: "com.example.hook",
    version: "1.0",
    architecture: layout.architecture,
    description: "An example tweak\nWhat it does, at length.",
)
control["Maintainer"] = "Example <example@example.com>"
control["Depends"] = "mobilesubstrate"

var writer = DebPackageWriter(control: control)
writer.modificationTime = commitTime          // seconds since 1970
writer.entries = [
    .file(try layout.tweakLibrary(named: "Hook"), copying: "build/Hook.dylib", mode: 0o755),
    .file(try layout.tweakFilter(named: "Hook"), contents: filterPlist),
]
writer.entries += try DebEntry.tree(fromDirectory: "build/HookPrefs.bundle",
                                    at: layout.preferenceBundle(named: "HookPrefs"))
writer.maintainerScripts[.postinst] = Data(layout.substitutingPlaceholders(in: template).utf8)
try writer.write(toPath: "build/com.example.hook_1.0_\(layout.architecture).deb")
```

The writer produces what `dpkg-deb --root-owner-group -Z<codec> -b` would:

- `debian-binary` (`2.0`), `control.tar.<ext>`, `data.tar.<ext>`, in that
  order, in an `ar` container with uid/gid 0 and mode 100644;
- GNU tar members named `./…`, directories with a trailing slash, the root
  `./` first, every missing parent directory added with mode 0755, sorted
  component-wise so a directory precedes its contents;
- every member root:wheel (uid 0, gid 0); modes as given (setuid included);
  symbolic links kept as links; names and link targets over 100 bytes in GNU
  long-name records;
- `control` first in `control.tar`, maintainer scripts with mode 0755, other
  control members (`conffiles`, `triggers`) with mode 0644;
- `Installed-Size` set from the entries (each regular file rounded up to a
  KiB, each directory and link one KiB), replacing any value it had;
- `zstd` by default, or `xz`, `gzip` or none, at dpkg-deb's default levels.
  libarchive's raw writer does the compression with every codec linked in;
  it runs single-threaded and unblocked, and gzip's timestamp is zero.

The output is deterministic: the same description gives the same bytes on any
machine, in any entry order. `write(toPath:)` writes a temporary file beside
the destination, flushes it and renames it over; a failure leaves nothing.

## Reading a package

```swift
let contents = try DebArchiveReader.contents(of: .path(debPath), contentsLimit: 64 * 1024)
let control = try contents.control()             // DebianControlFile
contents.controlFiles["postinst"]                // Data?
for entry in contents.entries { print(entry.path, entry.kind, entry.mode) }

let text = try DebArchiveReader.control(of: .path(debPath))   // only control.tar is opened
```

The reader refuses a first member other than `debian-binary`, a format other
than 2.0, `control.tar` after `data.tar` or either missing or repeated, a path
escaping the root or listed twice, and more than `maximumEntryCount` entries.

## Bootstrap layouts

`PackageLayout` mirrors `Scripts/package-deb.sh` and the Makefile's `FLAVOR`
table:

| flavor   | package prefix | Architecture      | `@ROOTFS@` |
|----------|----------------|-------------------|------------|
| rootless | `/var/jb`      | `iphoneos-arm64`  | (empty)    |
| roothide | (none)         | `iphoneos-arm64e` | `/rootfs`  |

A logical path (`/usr/bin/x`) maps to a package path (`/var/jb/usr/bin/x`);
`substitutingPlaceholders(in:)` fills `@PREFIX@` and `@ROOTFS@`. The `/var/jb`
here is the rootless package format, never a runtime install root: which
flavor to build for, and where the bootstrap is, come from apelind.

## Tests

```sh
swift test --scratch-path /private/tmp/apelin-spm
```

The Mach-O fixtures in `Tests/ApelinMachOTests/Fixtures/binaries` are built by
`build.sh` from `fixture.c` and committed. The package tests check every
layout and codec through the reader, check determinism, and — where
`dpkg-deb` is installed — run `dpkg-deb -I`, `-c`, `-f`, `-x` and `-e` on what
the writer produced and read packages `dpkg-deb -b` built.
