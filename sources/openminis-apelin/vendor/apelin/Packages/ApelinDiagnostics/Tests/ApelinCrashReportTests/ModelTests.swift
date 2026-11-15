// Ported from Xrash (XrashKit/Tests/XrashReportTests/ModelTests.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

@testable import ApelinCrashReport
import XCTest

final class ModelTests: XCTestCase {
    func testFaultingThreadIsBoundsChecked() {
        var crash = CrashReport()
        crash.faultingThreadIndex = 3
        XCTAssertNil(crash.faultingThread)
        crash.threads = (0 ..< 4).map(ReportThread.init(index:))
        XCTAssertEqual(crash.faultingThread?.index, 3)
    }
}
