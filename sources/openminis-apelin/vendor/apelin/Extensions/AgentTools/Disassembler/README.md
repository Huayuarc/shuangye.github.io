# Disassembler and Assembler agent tools

Two agent tool extensions for Apelin (milestone 1 plan, §6), built from this
one folder and shipped as two packages, each in a roothide and a rootless
deb:

| Package | Executable | Tools | Links | License |
|---|---|---|---|---|
| `wiki.qaq.apelin.agent-tools.disassembler` | `apelin-disassembler` | `disassemble{binary, address, count, arch?}`, `symbols{binary, filter?, kind?, limit?, offset?, arch?, output?}` (`output: file` sends the whole listing as an attachment) | Capstone, MachOReader | MIT, BSD-3-Clause, NCSA |
| `wiki.qaq.apelin.agent-tools.assembler` | `apelin-assembler` | `assemble{arch, source, address?, syntax?}` | Keystone | GPL-2.0-only, MIT, NCSA |

Keystone is GPLv2, so it links into `apelin-assembler` alone: the
disassembler package carries no GPL code (the packager refuses a disassembler
that defines `ks_asm`), and Apelin neither depends on nor recommends either
package. Both speak the protocol in `Packages/ApelinToolHost` and run as
mobile, in their own process, only when the agent calls them.

## Layout

```
Sources/MachOReader/        minimal Mach-O reader: fat/thin, 64-bit, segments, sections, LC_SYMTAB, LC_UUID (MIT)
Sources/DisassemblerTools/  disassemble and symbols, on Capstone (libcapstone-spm 0.1.3)
Sources/AssemblerTools/     assemble, on Keystone (libkeystone-spm 0.1.2, pinned by revision)
Sources/apelin-*/           the two executables: build the server, run it
Packaging/<tool>/           manifest.json, control, entitlements (disassembler), SOURCE.md.in (assembler)
Licenses/                   the reviewed notices both packages ship, and review.json with their hashes
Scripts/                    build-agent-tools.sh, package-agent-tool.sh
```

Each package installs, under its prefix (none for roothide, `/var/jb` for
rootless):

```
usr/libexec/apelin/agent-tools/apelin-<tool>
usr/share/apelin/agent-tools/<id>/manifest.json
usr/share/apelin/agent-tools/<id>/licenses/…
```

## Build, test, package

```sh
swift test                         # on the Mac: both extensions end to end through ToolHostClient
Scripts/build-agent-tools.sh [dir] # iPhoneOS arm64, then all four debs, verified
```

`swift test` also holds each `Packaging/<tool>/manifest.json` to what its
executable prints with `--describe`; change a tool's description or schema
in the code and the manifest together.

`package-agent-tool.sh` takes one built executable and makes one deb. It
refuses: a binary that is not thin arm64 for iOS, links `libvroot` or embeds a
build path; a notice that differs from its reviewed hash in
`Licenses/review.json`, or from the dependency's own copy; a pin in
`Package.resolved` other than the reviewed one; a signature with entitlements
other than the plist's (the assembler carries none; the disassembler carries
`platform-application`, `no-sandbox` and `storage.AppBundles`, so it can
read app bundles); anything group- or world-writable; a placeholder left in
what ships.

## Licenses

- The disassembler ships Apelin's MIT license, Capstone's
  `LICENSE.TXT`, `LICENSE_BSD_3_CLAUSE.txt` and `LICENSE_LLVM.TXT`, and
  libcapstone-spm's license.
- The assembler ships Apelin's MIT license, Keystone's `COPYING` (GPLv2),
  `EXCEPTIONS-CLIENT` and LLVM license, libkeystone-spm's license, and
  `SOURCE.md`, which names the corresponding-source archive the build writes
  beside the debs (`wiki.qaq.apelin.agent-tools.assembler_<version>_source.tar.xz`:
  this folder, `Packages/ApelinToolHost`, and both dependency checkouts) with
  its SHA-256, and the public repositories and revisions it was made from.
  Publish that archive wherever the assembler debs are published.
