import Foundation

/// A tweak's filter plist (`<Tweak>.plist` beside the dylib), as substrate
/// and the injectors that copy its format read it:
///
/// ```
/// { Filter = { Bundles = ( "com.apple.springboard" ); }; }
/// ```
///
/// `Bundles` names bundles that must be loaded in the process, `Executables`
/// executable names, `Classes` Objective-C classes that must exist. Within a
/// key any entry is enough; across keys every key present must match, unless
/// `Mode = Any`, when one is enough. `CoreFoundationVersion` is a `[min, max)`
/// pair (max optional) that must hold in every mode.
public struct InjectionFilter: Hashable, Sendable {
    public var bundles: [String]
    public var executables: [String]
    public var classes: [String]
    public var modeAny: Bool
    public var coreFoundationVersion: (minimum: Double, maximum: Double?)?

    /// Whether the plist had a `Filter` dictionary at all. Without one the
    /// injectors load the dylib into every process they inject.
    public var hasFilter: Bool

    public static func == (lhs: InjectionFilter, rhs: InjectionFilter) -> Bool {
        lhs.bundles == rhs.bundles && lhs.executables == rhs.executables && lhs.classes == rhs.classes
            && lhs.modeAny == rhs.modeAny && lhs.hasFilter == rhs.hasFilter
            && lhs.coreFoundationVersion?.minimum == rhs.coreFoundationVersion?.minimum
            && lhs.coreFoundationVersion?.maximum == rhs.coreFoundationVersion?.maximum
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundles)
        hasher.combine(executables)
        hasher.combine(classes)
        hasher.combine(modeAny)
        hasher.combine(hasFilter)
    }

    /// Filter plists are small; anything larger is not one.
    public static let maximumBytes = 64 * 1024

    /// Parses OpenStep, XML or binary plist data. Throws on anything that is
    /// not a dictionary, or a `Filter` key that is not one.
    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else {
            throw InjectionFilterError.tooLarge
        }
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw InjectionFilterError.notAPropertyList
        }
        guard let dictionary = root as? [String: Any] else { throw InjectionFilterError.notADictionary }
        guard let filterValue = dictionary["Filter"] else {
            self.init(
                bundles: [],
                executables: [],
                classes: [],
                modeAny: false,
                coreFoundationVersion: nil,
                hasFilter: false,
            )
            return
        }
        guard let filter = filterValue as? [String: Any] else { throw InjectionFilterError.notADictionary }
        func strings(_ key: String) -> [String] {
            (filter[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        func number(_ value: Any) -> Double? {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let text = value as? String {
                return Double(text)
            }
            return nil
        }
        var versions: (Double, Double?)?
        if let range = filter["CoreFoundationVersion"] as? [Any], let minimum = range.first.flatMap(number) {
            versions = (minimum, range.count > 1 ? number(range[1]) : nil)
        }
        self.init(
            bundles: strings("Bundles"),
            executables: strings("Executables"),
            classes: strings("Classes"),
            modeAny: (filter["Mode"] as? String) == "Any",
            coreFoundationVersion: versions,
            hasFilter: true,
        )
    }

    public init(
        bundles: [String],
        executables: [String],
        classes: [String],
        modeAny: Bool,
        coreFoundationVersion: (minimum: Double, maximum: Double?)?,
        hasFilter: Bool,
    ) {
        self.bundles = bundles
        self.executables = executables
        self.classes = classes
        self.modeAny = modeAny
        self.coreFoundationVersion = coreFoundationVersion
        self.hasFilter = hasFilter
    }
}

public enum InjectionFilterError: Error, Equatable, Sendable {
    case tooLarge
    case notAPropertyList
    case notADictionary
}

/// What is known about the process the tweak should land in, without looking
/// inside it.
public struct FilterTarget: Codable, Hashable, Sendable {
    /// The main bundle's identifier; nil for a bare executable.
    public var bundleIdentifier: String?
    /// The executable's file name.
    public var executableName: String
    /// `kCFCoreFoundationVersionNumber` of the device, when known.
    public var coreFoundationVersion: Double?

    public init(
        bundleIdentifier: String?,
        executableName: String,
        coreFoundationVersion: Double? = nil,
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.coreFoundationVersion = coreFoundationVersion
    }
}

/// The static answer: does the filter select this process?
public struct FilterMatch: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// The filter selects the process on what is known.
        case matches
        /// The filter rules the process out on what is known.
        case doesNotMatch
        /// The answer depends on something only the running process knows —
        /// a framework bundle not known to be loaded, an Objective-C class.
        case undetermined
    }

    public var verdict: Verdict
    /// One line per key decided, in plist key order: what matched, what did
    /// not, what could not be known.
    public var notes: [String]
}

extension InjectionFilter {
    public func evaluate(for target: FilterTarget) -> FilterMatch {
        guard hasFilter else {
            return FilterMatch(verdict: .matches, notes: ["No Filter dictionary: loaded into every injected process."])
        }
        var notes = [String]()

        // Three-valued per key: true, false, or nil for not knowable here.
        var keyResults = [Bool?]()

        if !bundles.isEmpty {
            if let main = target.bundleIdentifier, bundles.contains(main) {
                notes.append("Bundles: \(main) is loaded.")
                keyResults.append(true)
            } else if target.bundleIdentifier != nil, bundles.allSatisfy(Self.appOnlyIdentifiers.contains) {
                // None names a framework, so only the main bundle could match,
                // and it does not.
                notes.append("Bundles: none of \(bundles.joined(separator: ", ")) is the main bundle.")
                keyResults.append(false)
            } else {
                notes.append("Bundles: \(bundles.joined(separator: ", ")) may be loaded as a framework; not known statically.")
                keyResults.append(nil)
            }
        }
        if !executables.isEmpty {
            let hit = executables.contains(target.executableName)
            notes.append(hit
                ? "Executables: \(target.executableName) is listed."
                : "Executables: \(target.executableName) is not among \(executables.joined(separator: ", ")).")
            keyResults.append(hit)
        }
        if !classes.isEmpty {
            notes.append("Classes: \(classes.joined(separator: ", ")) can only be checked inside the process.")
            keyResults.append(nil)
        }

        var verdict: FilterMatch.Verdict
        if keyResults.isEmpty {
            // MobileLoader starts at "load" for all-keys mode and "skip" for
            // Mode = Any, and with no keys nothing changes either.
            notes.append(modeAny
                ? "Filter has no Bundles, Executables or Classes and Mode = Any: selects no process."
                : "Filter has no Bundles, Executables or Classes: selects every process.")
            verdict = modeAny ? .doesNotMatch : .matches
        } else if modeAny {
            verdict = keyResults.contains(true) ? .matches : keyResults.contains(nil) ? .undetermined : .doesNotMatch
        } else {
            verdict = keyResults.contains(false) ? .doesNotMatch : keyResults.contains(nil) ? .undetermined : .matches
        }

        if let range = coreFoundationVersion {
            if let version = target.coreFoundationVersion {
                let inside = version >= range.minimum && (range.maximum.map { version < $0 } ?? true)
                notes.append(inside
                    ? "CoreFoundationVersion: \(version) is in range."
                    : "CoreFoundationVersion: \(version) is outside the range.")
                if !inside {
                    verdict = .doesNotMatch
                }
            } else {
                notes.append("CoreFoundationVersion: the device's version is not known.")
                if verdict == .matches {
                    verdict = .undetermined
                }
            }
        }
        return FilterMatch(verdict: verdict, notes: notes)
    }

    /// `com.apple.UIKit` or a third-party framework id can be loaded into a
    /// process whose main bundle is something else. An app-style id cannot be
    /// told apart from a framework id by spelling, so only the well-known
    /// app-only case — the main bundle itself — decides `false`; everything
    /// else stays undetermined.
    ///
    /// Bundles that are only ever a main bundle. Extend when a template
    /// targets another system app.
    private static let appOnlyIdentifiers: Set<String> = [
        "com.apple.springboard", "com.apple.Preferences", "com.apple.mobilesafari", "com.apple.MobileSMS",
        "com.apple.mobilephone", "com.apple.mobilemail", "com.apple.camera", "com.apple.mobileslideshow",
        "com.apple.AppStore", "com.apple.Music", "com.apple.mobilenotes", "com.apple.MobileAddressBook",
    ]
}
