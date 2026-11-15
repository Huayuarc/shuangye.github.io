import ApelinCore
import ApelinProtocol
import ApelinReplay
import Foundation
import XCTest

/// `ReplayTransport` behind `ApelinService`: tasks replay exactly as
/// recorded, an approval holds an agent session, attaches are long polls,
/// pacing follows the recorded times, and plain operations answer the
/// latest matching reply.
final class ReplayTransportTests: XCTestCase {
    private func fixtures() throws -> ReplayFixtures {
        try ReplayFixtures.bundled()
    }

    private func recording(_ name: String, in fixtures: ReplayFixtures) throws -> ReplayFixtures.TaskRecording {
        try XCTUnwrap(fixtures.task(named: name), "no recording \(name) in the replay fixtures")
    }

    private func collect(_ service: ApelinService, _ handle: TaskHandle, after: EventSeq = .start) async throws -> [TaskEvent] {
        var events: [TaskEvent] = []
        for try await event in service.events(of: handle, afterSeq: after) {
            events.append(event)
        }
        return events
    }

    func testAgentSessionReplaysAsRecorded() async throws {
        let fixtures = try fixtures()
        let recording = try recording("a1-agent", in: fixtures)
        let service = ApelinService.replay(fixtures, pacing: .immediate)
        let response = try await service.send(recording.start.request.decode(AgentOpenRequest.self))
        XCTAssertEqual(try JSONValue(encoding: response), recording.start.response)
        let events = try await collect(service, response.task)
        XCTAssertEqual(events, recording.events)
        XCTAssertEqual(events.last?.payload?["state"]?.stringValue, "succeeded")
        XCTAssertTrue(events.contains { $0.kind == "toolCall" } && events.contains { $0.kind == "text" })
    }

    func testBuildsReplayAsRecorded() async throws {
        let fixtures = try fixtures()
        let service = ApelinService.replay(fixtures, pacing: .immediate)
        for (name, state) in [("d1-tweak-build", TaskState.succeeded), ("d2-build", .failed)] {
            let recording = try recording(name, in: fixtures)
            let handle = try await service.send(recording.start.request.decode(BuildStartRequest.self))
            XCTAssertEqual(handle.taskID, recording.taskID, name)
            let events = try await collect(service, handle)
            XCTAssertEqual(events, recording.events, name)
            XCTAssertEqual(events.last?.payload?["state"]?.stringValue, state.rawValue, name)
        }
    }

    func testApprovalHoldsTheSessionUntilTheAppApproves() async throws {
        let fixtures = try fixtures()
        let recording = try recording("c1-agent", in: fixtures)
        let gate = try XCTUnwrap(recording.events.firstIndex { $0.payload?["state"]?.stringValue == "waitingForApproval" })
        let service = ApelinService.replay(fixtures, pacing: .immediate)
        let opened = try await service.send(recording.start.request.decode(AgentOpenRequest.self))

        let held = try await service.attach(opened.task, afterSeq: .start, waitMilliseconds: 50)
        XCTAssertEqual(held.events, Array(recording.events[...gate]))
        XCTAssertEqual(held.state, .waitingForApproval)
        XCTAssertFalse(held.finished)
        let still = try await service.attach(opened.task, afterSeq: held.lastSeq, waitMilliseconds: 50)
        XCTAssertTrue(still.events.isEmpty, "nothing comes out before the approval")
        XCTAssertFalse(still.finished)

        let approval = try XCTUnwrap(fixtures.replies.last { $0.operation == .agentApprove })
        let request = try approval.request.decode(AgentApproveRequest.self)
        XCTAssertEqual(request.sessionID, opened.sessionID)
        _ = try await service.send(request)
        let rest = try await collect(service, opened.task, after: held.lastSeq)
        XCTAssertEqual(rest, Array(recording.events[(gate + 1)...]))
    }

    func testLogStreamOpensWithItsFilterAndReadsOn() async throws {
        let fixtures = try fixtures()
        let recording = try recording("d1-logs", in: fixtures)
        let service = ApelinService.replay(fixtures, pacing: .immediate)
        let opened = try await service.send(recording.start.request.decode(LogStreamRequest.self))
        XCTAssertEqual(opened.taskID, recording.taskID)
        XCTAssertFalse(opened.events.isEmpty)
        let rest = try await collect(service, TaskHandle(taskID: opened.taskID, kind: .logStream), after: opened.lastSeq)
        XCTAssertEqual(opened.events + rest, recording.events)
    }

    func testRecordedPacingReleasesEventsAsTimePasses() async throws {
        let fixtures = try fixtures()
        let recording = try recording("s1-steer", in: fixtures)
        let clock = ManualClock()
        let transport = ReplayTransport(fixtures: fixtures, pacing: .recorded(speed: 1, maxGap: 1.5, minGap: 0.05), clock: clock.read)
        let service = ApelinService(transport: transport)
        let opened = try await service.send(recording.start.request.decode(AgentOpenRequest.self))

        let first = try await service.attach(opened.task, afterSeq: .start, waitMilliseconds: 0)
        XCTAssertEqual(first.events, [recording.events[0]], "only the first event is out when the task starts")
        // The second event was recorded a second after the first, the third
        // in the same second as the second: 0.05 s after it.
        clock.advance(1)
        let second = try await service.attach(opened.task, afterSeq: first.lastSeq, waitMilliseconds: 0)
        XCTAssertEqual(second.events, [recording.events[1]])
        XCTAssertFalse(second.finished)
        clock.advance(3600)
        let rest = try await service.attach(opened.task, afterSeq: second.lastSeq, waitMilliseconds: 0)
        XCTAssertTrue(rest.finished)
        XCTAssertEqual(first.events + second.events + rest.events, recording.events)
    }

    func testAnAttachWaitsForItsBoundWhenNothingIsOut() async throws {
        let fixtures = try fixtures()
        let recording = try recording("d1-pty", in: fixtures)
        let service = ApelinService.replay(fixtures, pacing: .immediate)
        let handle = TaskHandle(taskID: recording.taskID, kind: .terminal)
        let all = try await service.attach(handle, afterSeq: .start, waitMilliseconds: 0)
        XCTAssertEqual(all.events, recording.events, "a task from before this run is all out")
        XCTAssertEqual(all.state, .running)
        let started = Date()
        let none = try await service.attach(handle, afterSeq: all.lastSeq, waitMilliseconds: 200)
        XCTAssertTrue(none.events.isEmpty)
        XCTAssertFalse(none.finished)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15, "the long poll ran out its wait")
    }

    func testPlainOperationsAnswerTheLatestMatchingReply() async throws {
        let fixtures = try fixtures()
        let service = ApelinService.replay(fixtures, pacing: .immediate)

        let lists = fixtures.replies.filter { $0.operation == .agentList }
        XCTAssertGreaterThan(lists.count, 1)
        let listed = try await service.send(AgentListRequest())
        XCTAssertEqual(try JSONValue(encoding: listed), lists.last?.response)

        let check = try XCTUnwrap(fixtures.replies.first { $0.operation == .projectCheck })
        let checked = try await service.send(check.request.decode(ProjectCheckRequest.self))
        XCTAssertEqual(try JSONValue(encoding: checked), check.response)

        let hello = try await service.send(HelloRequest())
        XCTAssertTrue(hello.operations.contains(.agentOpen))

        do {
            _ = try await service.send(CrashListRequest())
            XCTFail("no crashList was recorded")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .unavailable)
        }
        do {
            _ = try await service.attach(TaskHandle(taskID: TaskID("not-a-task"), kind: .build), afterSeq: .start, waitMilliseconds: 0)
            XCTFail("an unknown task was attached")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .notFound)
        }
    }
}

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = PthreadLock()
    private var now: TimeInterval = 1000

    var read: @Sendable () -> TimeInterval {
        { [self] in lock.withLock { now } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { now += seconds }
    }
}
