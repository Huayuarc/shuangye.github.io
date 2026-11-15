import ApelinDiagnosticsCore
import Foundation

/// What to confirm: a tweak, the process it should be in, and the marker line
/// its constructor logs (templates log `<marker>` once from their constructor;
/// ApelinHello logs `ApelinHello: loaded into <process>`).
public struct LoadConfirmationRequest: Codable, Hashable, Sendable {
    /// Case-sensitive text the tweak's constructor logs.
    public var marker: String
    /// The subsystem the marker is logged under, when the template uses one.
    public var markerSubsystem: String?
    /// The target's executable name, `SpringBoard`.
    public var targetExecutable: String
    /// The target's main bundle identifier, for the filter check.
    public var targetBundleIdentifier: String?
    /// The installed dylib, spelled any way that resolves on this device.
    /// Reported, never looked up in the target: see `ConfirmLoaded`.
    public var dylibPath: String
    /// The filter plist's bytes, as installed beside the dylib.
    public var filterPlist: Data?
    /// The device's `kCFCoreFoundationVersionNumber`, for a filter that asks.
    public var coreFoundationVersion: Double?
    /// How long to listen for the marker, 0.1–60 seconds.
    public var logWindow: TimeInterval

    public init(
        marker: String,
        markerSubsystem: String? = nil,
        targetExecutable: String,
        targetBundleIdentifier: String? = nil,
        dylibPath: String,
        filterPlist: Data? = nil,
        coreFoundationVersion: Double? = nil,
        logWindow: TimeInterval = 15,
    ) {
        self.marker = marker
        self.markerSubsystem = markerSubsystem
        self.targetExecutable = targetExecutable
        self.targetBundleIdentifier = targetBundleIdentifier
        self.dylibPath = dylibPath
        self.filterPlist = filterPlist
        self.coreFoundationVersion = coreFoundationVersion
        self.logWindow = logWindow
    }

    /// The fixed log request the marker check makes.
    public var markerFilter: LogFilter {
        LogFilter(
            subsystem: markerSubsystem,
            process: targetExecutable,
            messageContains: marker,
            duration: logWindow,
            maxEntries: 20,
        )
    }
}

public enum EvidenceStatus: String, Codable, Sendable {
    /// This evidence says the tweak is loaded (or, for the filter, selects
    /// the target).
    case confirmed
    /// It was looked for and is not there.
    case absent
    /// It could not be looked for: the log read failed, the filter plist is
    /// missing or unreadable, or the filter cannot be decided without looking
    /// inside the process.
    case unavailable
    /// It is deliberately never looked for: the target's image list.
    case notRead
}

public struct MarkerEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
}

/// Always `notRead`: kept so a caller still sees the three answers apart.
public struct ImageEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
}

public struct FilterEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
}

/// The three answers, kept apart: none of them alone is proof, and a caller
/// shows each with its own reason.
public struct LoadConfirmation: Codable, Hashable, Sendable {
    public var marker: MarkerEvidence
    public var image: ImageEvidence
    public var filter: FilterEvidence
    /// The trigger threw: the respring or relaunch may not have happened.
    public var triggerFailure: String?

    /// Loaded if the process says so itself, by its marker line. The filter
    /// only explains a miss.
    public var isLoaded: Bool {
        marker.status == .confirmed
    }
}

/// The marker and the filter. The target's image list is never read: on the
/// iOS 27.0.1 vphone (roothide), reading SpringBoard's image list from
/// apelin-diagnostics panicked the kernel ("VM entry … lock is invalid",
/// vm_entry_lock.c:168) on 2026-10-17: twice while the task-port read of
/// dyld's image infos was in place, then once more through the kernel's
/// region paths (`proc_pidinfo PROC_PIDREGIONPATHINFO`) alone. Both readers
/// are gone.
/// Documents/Research/Device-Validation.md has the record.
public struct ConfirmLoaded: Sendable {
    private let logs: any LogEvidenceSource

    /// What `run` reports as it goes, so a caller can record where it was if
    /// the device goes down under it.
    public enum Stage: String, Sendable {
        /// The marker read has started.
        case listening
        /// The trigger is about to run.
        case trigger
    }

    public init(logs: any LogEvidenceSource) {
        self.logs = logs
    }

    /// Listens for the marker while `trigger` (a respring, a relaunch) runs,
    /// then checks the filter. With no trigger, the marker must be logged
    /// inside the window by something the caller already set going: the
    /// live log has no history.
    public func run(
        _ request: LoadConfirmationRequest,
        trigger: (@Sendable () throws -> Void)? = nil,
        stage: (@Sendable (Stage) -> Void)? = nil,
    ) -> LoadConfirmation {
        let filter = Self.evaluateFilter(request)

        let logs = logs
        let markerFilter = request.markerFilter
        let box = ResultBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Result { try logs.readLogs(markerFilter) }
            group.leave()
        }
        stage?(.listening)
        // The stream has to be listening before the event it waits for.
        Thread.sleep(forTimeInterval: 0.5)
        if trigger != nil {
            stage?(.trigger)
        }
        let triggerError = Self.runTrigger(trigger)
        group.wait()
        // Set before `leave()`, so it is there once `wait()` returns.
        let markerResult = box.value!

        return LoadConfirmation(
            marker: Self.evaluateMarker(markerResult, request: request),
            image: Self.imageNotRead,
            filter: filter,
            triggerFailure: triggerError.map { "\($0)" },
        )
    }

    private static func runTrigger(_ trigger: (@Sendable () throws -> Void)?) -> Error? {
        do {
            try trigger?()
            return nil
        } catch {
            return error
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<LogReadResult, Error>?
    }

    // MARK: Pure evaluation, one per evidence

    /// The image evidence, always. It names no iOS version: it holds on
    /// every one, and an agent on iOS 17 read "the iOS 27 kernel" as a
    /// rule for another system.
    public static let imageNotRead = ImageEvidence(
        status: .notRead,
        detail: "The target's image list is never read, on any iOS version: reading it panicked the kernel on a test device.",
    )

    public static func evaluateMarker(
        _ result: Result<LogReadResult, Error>,
        request: LoadConfirmationRequest,
    ) -> MarkerEvidence {
        switch result {
        case let .failure(error):
            return MarkerEvidence(status: .unavailable, detail: "The log read failed: \(error.localizedDescription)")
        case let .success(read):
            // The source may filter more loosely than the request; this is
            // the check that counts.
            let filter = request.markerFilter
            let hits = read.entries.filter(filter.matches)
            if hits.isEmpty {
                return MarkerEvidence(
                    status: .absent,
                    detail: "No line containing \"\(request.marker)\" from \(request.targetExecutable) in \(Int(request.logWindow)) s.",
                )
            }
            let pids = Set(hits.map(\.pid)).sorted().map(String.init).joined(separator: ", ")
            return MarkerEvidence(status: .confirmed, detail: "Marker logged by pid \(pids).")
        }
    }

    public static func evaluateFilter(_ request: LoadConfirmationRequest) -> FilterEvidence {
        guard let data = request.filterPlist else {
            return FilterEvidence(status: .unavailable, detail: "No filter plist was given.")
        }
        let filter: InjectionFilter
        do {
            filter = try InjectionFilter(data: data)
        } catch {
            return FilterEvidence(status: .unavailable, detail: "The filter plist could not be read: \(error).")
        }
        let match = filter.evaluate(for: FilterTarget(
            bundleIdentifier: request.targetBundleIdentifier,
            executableName: request.targetExecutable,
            coreFoundationVersion: request.coreFoundationVersion,
        ))
        let status: EvidenceStatus = switch match.verdict {
        case .matches: .confirmed
        case .doesNotMatch: .absent
        case .undetermined: .unavailable
        }
        return FilterEvidence(status: status, detail: match.notes.joined(separator: " "))
    }
}
