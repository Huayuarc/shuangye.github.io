// Ported from Xrash (XrashKit/Sources/XrashReport/BinaryImages.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

/// The one lookup every decoder and renderer needs, written once so the bounds
/// check cannot be forgotten in the next one. Public because apelin-diagnostics
/// names a crashed frame's image with `image(for:)`.
public extension [BinaryImage] {
    /// The image a frame names — nil when it names none, or names one the
    /// report never listed, which a truncated file does.
    func image(for frame: Frame) -> BinaryImage? {
        frame.imageIndex.flatMap { indices.contains($0) ? self[$0] : nil }
    }

    /// The image whose mapped range holds `address` — nil when none does.
    /// A zero-sized image has no range and never matches.
    func index(containing address: UInt64) -> Int? {
        firstIndex { address >= $0.base && $0.size > 0 && address - $0.base < $0.size }
    }
}
