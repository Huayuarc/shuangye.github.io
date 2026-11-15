import Foundation

/// What this device's CPU implements, as the kernel reports it
/// (`hw.optional.arm.FEAT_*`). Apple ships its compilers for the M1 only,
/// and the retarget leaves their machine code as it is, so a few
/// instructions older chips lack decide what runs where — found by
/// disassembling every tool against `apple-a11`/`apple-a12` and confirmed on
/// an A12Z (`Documents/Research/2026-10-17-Toolchain-Retarget.md` ▸ Older
/// CPUs):
///
/// - `ldapr` (FEAT_LRCPC) runs in clang's and libLTO's static initialisers:
///   without it (A11 and older) no tool starts.
/// - `eor3` (FEAT_SHA3) is in LLVM's xxh3, which hashes every clang module
///   written: without it building a module traps, and Swift builds the SDK's
///   modules on every cold compile.
/// - `udot` (FEAT_DotProd) is in swift-frontend's wide popcounts.
///
/// On the Mac, where the harness runs the same checks, everything is there.
public enum HostCPU {
    /// Inspect only the fixed system C++ runtime; never load an inspected tool.
    public static func hasLibcxxSymbol(_ name: String) -> Bool {
        #if os(iOS)
            guard !name.utf8.contains(0), let image = dlopen("/usr/lib/libc++.1.dylib", RTLD_LAZY | RTLD_LOCAL) else {
                return false
            }
            defer { dlclose(image) }
            return dlsym(image, name) != nil
        #else
            return true
        #endif
    }

    /// Whether the kernel reports `feature` (`FEAT_SHA3`). A key the kernel
    /// does not know reads as absent.
    public static func has(_ feature: String) -> Bool {
        #if os(iOS)
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.optional.arm.\(feature)", &value, &size, nil, 0) == 0 else { return false }
            return value != 0
        #else
            return true
        #endif
    }

    /// Whether the toolchain runs here at all.
    public static var runsToolchain: Bool {
        has("FEAT_LRCPC")
    }

    /// Fallback for CLT 27.0 records predating per-release requirements.
    public static var runsSwift: Bool {
        has("FEAT_SHA3") && has("FEAT_DotProd")
    }

    /// Why the toolchain cannot run here, or nil when it can.
    public static var toolchainRefusal: String? {
        runsToolchain ? nil
            : "This device's CPU lacks instructions Apple's compilers use (FEAT_LRCPC, from the A12 on), "
            + "so the available Apple toolchains cannot run on it."
    }

    /// Fallback refusal for CLT 27.0; reviewed releases carry their own requirements.
    public static var swiftRefusal: String? {
        runsSwift ? nil
            : "Swift cannot run on this device: Apple's Swift compiler uses instructions its CPU lacks "
            + "(FEAT_SHA3 and FEAT_DotProd, from the A13 on). C, C++ and Objective-C without modules still work."
    }
}
