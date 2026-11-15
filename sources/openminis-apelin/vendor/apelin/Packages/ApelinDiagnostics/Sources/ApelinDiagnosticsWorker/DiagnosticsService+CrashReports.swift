import ApelinCore
import ApelinCrashBlame
import ApelinCrashReport
import ApelinCrashSymbols
import ApelinDiagnostics
import ApelinProtocol
import Foundation

extension DiagnosticsService {
    // MARK: Crash reports

    /// Report ids are file names, looked up in icli's crash directories.
    public static func isValidReportID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !CanonicalPath.containsNUL(id) && !id.hasPrefix(".")
            && id.utf8.count <= 255 && Diagnostics.crashReportExtensions.contains(where: id.hasSuffix)
    }

    func crashList(_ request: CrashListRequest) throws -> CrashListResponse {
        let references = try mapped {
            try diagnostics.listCrashReports(CrashReportListRequest(
                processName: request.process,
                limit: CrashReportListRequest.limitRange.upperBound,
            ))
        }
        var reports: [CrashReportSummary] = []
        for reference in references where Self.isValidReportID(reference.name) {
            var metadata = stat()
            let found = stat(reference.path, &metadata) == 0
            let modified = found
                ? Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
                : Date.distantPast
            let summary = ReportDecoder.summary(
                path: reference.path,
                byteCount: found ? UInt64(metadata.st_size) : 0,
                modified: modified,
            )
            if let since = request.since, summary.date < since {
                continue
            }
            reports.append(CrashReportSummary(
                id: reference.name,
                process: summary.processName,
                bundleID: summary.bundleID,
                date: summary.date,
                exceptionType: summary.bugType,
            ))
        }
        reports.sort { $0.date > $1.date }
        return CrashListResponse(reports: reports)
    }

    /// The report's text: icli reads what mobile can; anything else is the
    /// host's to open by id, handed over read-only.
    func reportData(_ id: String) async throws -> Data {
        guard Self.isValidReportID(id) else { throw ApelinError(.badRequest, "\(id) is not a crash report ID.") }
        for directory in Diagnostics.crashDirectories {
            let path = directory + "/" + id
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let text = try? await blocking({ try diagnostics.readCrashReport(path: path, maxBytes: Diagnostics.crashTextRange.upperBound) }), !text.truncated {
                return Data(text.text.utf8)
            }
            break
        }
        let (response, descriptor) = try await host.crashOpen(id: id)
        guard let descriptor else { throw ApelinError(.internal, "The host did not hand over the crash report file.") }
        defer { descriptor.close() }
        guard response.size <= Int64(Diagnostics.maximumCrashFileBytes) else {
            throw ApelinError(.badRequest, "\(id) is larger than \(Diagnostics.maximumCrashFileBytes >> 20) MB.")
        }
        return FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: false).readDataToEndOfFile()
    }

    func crashSymbolicate(_ request: CrashSymbolicateRequest) async throws -> CrashSymbolicateResponse {
        let data = try await reportData(request.id)
        let report: Report
        do {
            report = try ReportDecoder.decode(data, fileName: request.id)
        } catch {
            throw ApelinError(.badRequest, "\(request.id) could not be read as a crash report: \(error)")
        }
        guard var crash = report.crash else { throw ApelinError(.badRequest, "\(request.id) is not a crash report.") }
        let dsyms = try ProjectDSYMs(
            directories: request.projectID.map { try ProjectFolders.dsymDirectories(projectID: $0, home: home) }
                ?? [],
            depth: 8,
        )
        let symbolicator = Symbolicator(dsyms: dsyms) { path in
            // Symbols come from the project's dSYMs; no image is opened by a
            // path a report names.
            throw ApelinError(.denied, "\(path) is not opened: symbols come only from the project's dSYMs.")
        }
        crash = await symbolicator.symbolicate(crash)
        let matched = crash.images.compactMap { dsyms.url(forUUID: $0.uuid) != nil ? $0.uuid : nil }
        let thread = crash.faultingThread ?? crash.threads.first
        let frames = (thread?.frames ?? []).prefix(128).enumerated().map { index, frame in
            ApelinProtocol.SymbolicatedFrame(
                index: index,
                image: crash.images.image(for: frame)?.name ?? "???",
                address: "0x" + String(frame.address, radix: 16),
                symbol: frame.symbol,
                file: frame.sourceFile,
                line: frame.sourceLine,
            )
        }
        return CrashSymbolicateResponse(
            id: request.id,
            process: crash.process.name,
            exceptionType: crash.exception?.type,
            matchedImageUUIDs: matched,
            crashedThread: Array(frames),
            suspects: Blame.suspects(in: crash, packages: nil).map(\.imageName),
        )
    }
}
