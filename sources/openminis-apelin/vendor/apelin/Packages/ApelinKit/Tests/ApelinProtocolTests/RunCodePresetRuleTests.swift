@testable import ApelinProtocol
import XCTest

/// The words-only preset rule both the agent and the session host read: a
/// table of argvs, each with the paths it must keep in the project, or nil
/// when its words alone make it no preset.
final class RunCodePresetRuleTests: XCTestCase {
    func testTable() {
        let table: [([String], [String]?)] = [
            // File tools: options are fine, the rest are paths.
            (["ls", "-la"], []),
            (["cat", "Sources/main.m"], ["Sources/main.m"]),
            (["head", "-n", "5", "Sources/main.m"], ["5", "Sources/main.m"]),
            (["wc", "-l", "--", "Sources/main.m", "-x"], ["Sources/main.m", "-x"]),
            (["cat", "-"], []),
            (["stat", "--format=%z", "a"], ["%z", "a"]),
            (["cat", "/etc/passwd"], ["/etc/passwd"]),
            // A list of names read from a file, or a file written.
            (["file", "-f", "Info.plist"], nil),
            (["file", "-bf", "Info.plist"], nil),
            (["file", "-C", "-m", "magic"], nil),
            (["file", "--comp", "-m", "magic"], nil),
            (["file", "--files-from", "Info.plist"], nil),
            (["file", "--files=Info.plist"], nil),
            (["wc", "--files0-from=Info.plist"], nil),
            (["wc", "--files0=Info.plist"], nil),
            (["cat", "--files-from=Info.plist"], nil),
            (["ls", "-C"], []),
            // file: only options that change how it prints. A magic file
            // echoes its lines back; -z and -Z run decompressors.
            (["file", "-b", "Info.plist"], ["Info.plist"]),
            (["file", "-bi", "--mime-type", "-L", "-0", "Info.plist"], ["Info.plist"]),
            (["file", "--brief", "--mime", "--mime-encoding", "-N", "-k", "-h", "a"], ["a"]),
            (["file", "-m/etc/passwd", "Info.plist"], nil),
            (["file", "-m", "magic", "Info.plist"], nil),
            (["file", "-bm/etc/passwd", "Info.plist"], nil),
            (["file", "--magic-file=x:/etc/passwd", "Info.plist"], nil),
            (["file", "-z", "a.gz"], nil),
            (["file", "-Z", "a.gz"], nil),
            (["file", "-bz", "a.gz"], nil),
            (["file", "--uncompress", "a.gz"], nil),
            (["file", "--uncompress-noreport", "a.gz"], nil),
            (["file", "--mime=x", "a"], nil),
            // ls follows no link out of the project and walks no tree.
            (["ls", "-L", "Sources"], nil),
            (["ls", "-laL", "Sources"], nil),
            (["ls", "-R"], nil),
            (["ls", "-lR"], nil),
            (["ls", "--recursive"], nil),
            (["ls", "--rec"], nil),
            (["ls", "--dereference"], nil),
            (["ls", "--dereference-command-line-symlink-to-dir"], nil),
            (["ls", "--deref"], nil),
            // plutil prints, and only prints.
            (["plutil", "-p", "Info.plist"], ["Info.plist"]),
            (["plutil", "-p", "Info.plist", "-o", "copy.plist"], nil),
            (["plutil", "-convert", "xml1", "Info.plist"], nil),
            (["plutil", "Info.plist"], nil),
            // git: three read-only subcommands, nothing that writes, runs,
            // moves or reaches a submodule, abbreviated or not.
            (["git", "status"], []),
            (["git", "diff", "--stat"], []),
            (["git", "log", "--oneline", "-n", "5"], ["5"]),
            (["git", "diff", "--", "Sources"], ["Sources"]),
            (["git", "commit", "-m", "x"], nil),
            (["git"], nil),
            (["git", "diff", "--output=/tmp/x"], nil),
            (["git", "log", "--output", "log.txt"], nil),
            (["git", "log", "--out=log.txt"], nil),
            (["git", "diff", "-o", "diff.txt"], nil),
            (["git", "diff", "-ofile"], nil),
            (["git", "diff", "--ext-diff"], nil),
            (["git", "log", "-p", "--textconv"], nil),
            (["git", "status", "-c", "core.fsmonitor=x"], nil),
            (["git", "diff", "--no-index", "/etc/hosts", "Info.plist"], nil),
            (["git", "log", "--git-dir=/var"], nil),
            (["git", "status", "--work-tree", "/"], nil),
            (["git", "log", "--exec-path=/tmp"], nil),
            (["git", "status", "--ignore-sub=none"], nil),
            (["git", "diff", "--submodule=diff"], nil),
            (["git", "log", "--recurse-submodules"], nil),
            // A short option with a value attached: only numbers and the
            // pickaxe's regex or string. -O reads an order file.
            (["git", "diff", "-U5", "-M50%", "-C30", "-B50/60", "-l100"], []),
            (["git", "log", "-n5", "-10", "-Gfoo", "-Sbar"], []),
            (["git", "log", "-p", "-5"], []),
            (["git", "diff", "-O/etc/passwd"], nil),
            (["git", "diff", "-O", "order.txt"], nil),
            (["git", "diff", "-Ux"], nil),
            (["git", "diff", "-M/etc"], nil),
            (["git", "diff", "-cfoo"], nil),
            (["git", "diff", "-c"], nil),
            (["git", "diff", "-C/"], nil),
            (["git", "log", "-L1,5:/etc/passwd"], nil),
            // A bundle of flags that take no value, per subcommand; status's
            // -u with its mode attached. After log, -c is a combined diff.
            (["git", "status", "-sb"], []),
            (["git", "status", "-uno"], []),
            (["git", "status", "-unormal"], []),
            (["git", "status", "-uall"], []),
            (["git", "status", "-sbuno"], []),
            (["git", "status", "-zv"], []),
            (["git", "status", "-su"], []),
            (["git", "diff", "-pw"], []),
            (["git", "diff", "-sR"], []),
            (["git", "diff", "-pM"], []),
            (["git", "diff", "-C"], []),
            (["git", "diff", "-C", "Sources"], ["Sources"]),
            (["git", "log", "-pw"], []),
            (["git", "log", "-c"], []),
            (["git", "log", "-pcm"], []),
            (["git", "log", "-m", "-p"], []),
            // Anything else in a bundle still refuses.
            (["git", "status", "-ufoo"], nil),
            (["git", "status", "-usb"], nil),
            (["git", "status", "-sp"], nil),
            (["git", "status", "-c"], nil),
            (["git", "status", "-C"], nil),
            (["git", "status", "-sC"], nil),
            (["git", "diff", "-pc"], nil),
            (["git", "diff", "-pO"], nil),
            (["git", "diff", "-pOorder"], nil),
            (["git", "diff", "-po"], nil),
            (["git", "diff", "-Mp"], nil),
            (["git", "diff", "-pC/etc"], nil),
            (["git", "diff", "-pSfoo"], nil),
            (["git", "log", "-pL1,5:/etc/passwd"], nil),
            (["git", "log", "-pu"], nil),
            (["git", "log", "-mO"], nil),
            // Nothing that verifies a signature, which starts gpg.
            (["git", "log", "--show-signature"], nil),
            (["git", "log", "--show-sig"], nil),
            (["git", "log", "--format=%G?"], nil),
            (["git", "log", "--pretty=format:%h %GS"], nil),
            (["git", "log", "--format=%h %s"], ["%h %s"]),
            // git's format parser takes +, - or a space between % and the
            // placeholder; %x escapes are printed, never parsed again.
            (["git", "log", "--format=%+G?"], nil),
            (["git", "log", "--format=%-GS"], nil),
            (["git", "log", "--format=% GK"], nil),
            (["git", "log", "--pretty=tformat:%h%+GG"], nil),
            (["git", "log", "--format=%x25G"], ["%x25G"]),
            (["git", "log", "--format=%+gs %-h"], ["%+gs %-h"]),
            // Anything else is no preset.
            (["rm", "-rf", "."], nil),
            (["/bin/cat", "a"], nil),
            (["cat", "a\0b"], nil),
            ([], nil),
        ]
        for (argv, paths) in table {
            XCTAssertEqual(RunCodePresetRule.pathArguments(of: argv), paths, "\(argv)")
        }
    }

    func testAbbreviations() {
        XCTAssertTrue(RunCodePresetRule.names("--files0", oneOf: ["--files0-from"]))
        XCTAssertTrue(RunCodePresetRule.names("--files0-from=x", oneOf: ["--files0-from"]))
        XCTAssertTrue(RunCodePresetRule.names("--outputs", oneOf: ["--output"]))
        XCTAssertFalse(RunCodePresetRule.names("--", oneOf: ["--output"]))
        XCTAssertFalse(RunCodePresetRule.names("-o", oneOf: ["--output"]))
        XCTAssertFalse(RunCodePresetRule.names("--stat", oneOf: ["--output"]))
    }
}
