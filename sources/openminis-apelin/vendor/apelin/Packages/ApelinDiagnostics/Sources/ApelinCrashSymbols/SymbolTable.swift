// Ported from Xrash (XrashKit/Sources/XrashSymbols/SymbolTable.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

import Foundation

/// Where every function in one image starts, sorted, with the names in a single
/// blob beside them.
///
/// An address resolves to the last function that starts at or before it. An
/// entry with no name is a boundary rather than an answer: `LC_FUNCTION_STARTS`
/// knows where a stripped function begins even though nothing knows what it is
/// called, and without that boundary the stripped function would answer with
/// the name of whatever came before it.
///
/// The whole table is one `[UInt64]`, one `[UInt32]` and one `Data`, because a
/// dyld shared cache holds a few thousand images and the alternative — an array
/// of structs with a `String` each — is a few million small allocations.
public struct SymbolTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Bytes past the start of the image, which is `__TEXT`'s vmaddr.
        public var offset: UInt64
        public var name: String?

        public init(offset: UInt64, name: String?) {
            self.offset = offset
            self.name = name
        }
    }

    private var offsets: [UInt64]
    /// Index into `names`, or `noName` for a boundary.
    private var nameIndices: [UInt32]
    /// NUL-separated names.
    private var names: Data

    private static let noName = UInt32.max

    /// How many entries survived the merge. Nothing outside this module asks;
    /// the tests do, which is why it is not private.
    var count: Int {
        offsets.count
    }

    public var isEmpty: Bool {
        offsets.isEmpty
    }

    /// Sorts and merges: at one offset a name always wins over a boundary, and
    /// a repeated offset is kept once.
    public init(entries: [Entry]) {
        var offsets = [UInt64]()
        var nameIndices = [UInt32]()
        var names = Data()
        var index = [String: UInt32]()

        offsets.reserveCapacity(entries.count)
        nameIndices.reserveCapacity(entries.count)
        for entry in entries.sorted(by: { left, right in
            left.offset == right.offset ? (left.name != nil && right.name == nil) : left.offset < right.offset
        }) {
            if offsets.last == entry.offset {
                continue // the named one sorted first, so this adds nothing
            }
            offsets.append(entry.offset)
            guard let name = entry.name else {
                nameIndices.append(Self.noName)
                continue
            }
            if let known = index[name] {
                nameIndices.append(known)
            } else {
                let start = UInt32(clamping: names.count)
                names.append(contentsOf: name.utf8)
                names.append(0)
                index[name] = start
                nameIndices.append(start)
            }
        }

        self.offsets = offsets
        self.nameIndices = nameIndices
        self.names = names
    }

    /// The function containing `offset`, or nil when the last start at or below
    /// it has no name — or when there is nothing below it at all.
    public func lookup(offset: UInt64) -> (name: String, startOffset: UInt64)? {
        guard let position = index(notAfter: offset) else { return nil }
        let nameIndex = nameIndices[position]
        guard nameIndex != Self.noName, let name = name(at: nameIndex) else { return nil }
        return (name, offsets[position])
    }

    /// The largest index whose offset is at or below `offset`.
    private func index(notAfter offset: UInt64) -> Int? {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if offsets[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    private func name(at index: UInt32) -> String? {
        let start = names.startIndex + Int(index)
        guard start < names.endIndex else { return nil }
        var scan = start
        while scan < names.endIndex, names[scan] != 0 {
            scan += 1
        }
        guard scan > start else { return nil }
        return String(decoding: names[start ..< scan], as: UTF8.self)
    }
}
