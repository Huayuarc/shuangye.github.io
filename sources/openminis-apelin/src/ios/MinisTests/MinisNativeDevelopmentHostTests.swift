import XCTest
@testable import Minis
import MinisNativeDevelopment

@MainActor
final class MinisNativeDevelopmentHostTests: XCTestCase {
    private func resetContext() {
        MinisDevelopmentContextStore.shared.clearSelection()
    }

    func testNativePresetIsNotAdvertisedWithoutBackend() throws {
        let names = Set(MinisApelinTools.definitions.map(\.name))
        XCTAssertFalse(names.contains("createMarker"))
        XCTAssertFalse(names.contains("apelin_create_marker"))
        XCTAssertEqual(names, [
            "apelin_skill_list", "apelin_skill_read",
            "apelin_host_environment", "apelin_integration_status"
        ])

        let status = try MinisApelinTools.execute(
            name: "apelin_integration_status", arguments: [:])
        XCTAssertTrue(status.contains("\"backendConnected\" : false"))
        XCTAssertFalse(MinisNativeDevelopmentHost.shared.backendAvailable)
    }

    #if os(iOS)
    func testIOSLauncherFailsClosedWithoutRetainingSignerOrConnection() async throws {
        defer { resetContext() }
        try MinisDevelopmentContextStore.shared.selectVerifiedProject(id: "verified-project")
        let context = try XCTUnwrap(MinisDevelopmentContextStore.shared.snapshot)
        let project = ProjectRegistration(id: context.projectID, root: "/trusted/project")

        do {
            try await MinisNativeDevelopmentHost.shared.connect(
                executable: URL(fileURLWithPath: "/trusted/bundled/native-development-service"),
                project: project, sessions: ["session-1"], context: context)
            XCTFail("ordinary iOS must not claim the unsupported service launcher is available")
        } catch let error as NativeError {
            XCTAssertEqual(error, .unsupportedPlatform)
        }

        XCTAssertFalse(MinisNativeDevelopmentHost.shared.backendAvailable)
    }
    #endif

    func testContextChangesKeepBackendUnavailableAndInvalidateApprovals() throws {
        defer { resetContext() }
        try MinisDevelopmentContextStore.shared.selectVerifiedProject(id: "project-a")
        let first = try XCTUnwrap(MinisDevelopmentContextStore.shared.snapshot)

        MinisDevelopmentContextStore.shared.updateLocalSettings(
            mode: .relaxed, asksBeforeScreen: false)
        let second = try XCTUnwrap(MinisDevelopmentContextStore.shared.snapshot)

        XCTAssertNotEqual(first.revision, second.revision)
        XCTAssertEqual(second.projectID, first.projectID)
        XCTAssertFalse(MinisNativeDevelopmentHost.shared.backendAvailable)
        XCTAssertTrue(MinisDevelopmentApprovals.shared.pending.isEmpty)
    }

    func testChallengeExpiryRejectsExpiredBoundaryAndNonFiniteValues() {
        XCTAssertTrue(MinisNativeDevelopmentHost.isChallengeLive(expiresAt: 11, now: 10))
        XCTAssertFalse(MinisNativeDevelopmentHost.isChallengeLive(expiresAt: 10, now: 10))
        XCTAssertFalse(MinisNativeDevelopmentHost.isChallengeLive(expiresAt: 9, now: 10))
        XCTAssertFalse(MinisNativeDevelopmentHost.isChallengeLive(expiresAt: .infinity, now: 10))
        XCTAssertFalse(MinisNativeDevelopmentHost.isChallengeLive(expiresAt: 11, now: .nan))
    }

    func testSessionCancelDeniesItsPendingApproval() async throws {
        let invocation = try MinisDevelopmentApprovals.Invocation(
            sessionID: "cancelled-session", projectID: "verified-project",
            tool: NativeOperation.createMarker.rawValue, arguments: [:],
            workingDirectory: "/trusted/project", descriptionDigest: "digest")
        let approval = Task { @MainActor in
            await MinisDevelopmentApprovals.shared.request(invocation, reason: "test")
        }

        while MinisDevelopmentApprovals.shared.pending.isEmpty {
            await Task.yield()
        }
        MinisNativeDevelopmentHost.shared.cancel(sessionID: invocation.sessionID)

        let allowed = await approval.value
        XCTAssertFalse(allowed)
        XCTAssertTrue(MinisDevelopmentApprovals.shared.pending.isEmpty)
        XCTAssertFalse(MinisNativeDevelopmentHost.shared.backendAvailable)
    }

    func testUnknownNativeOperationHasNoTrustedReadAdapter() {
        XCTAssertThrowsError(
            try MinisDevelopmentPolicy.authorizeIntegrationRead(name: "createMarker"))
        XCTAssertThrowsError(
            try MinisApelinTools.execute(name: "createMarker", arguments: [:]))
    }
}
