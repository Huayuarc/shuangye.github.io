import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Testing

@Suite("The agent's notices on the task")
struct NoticeRelayTests {
    @Test
    func `a notice reaches the task as a notice event, its title only when given`() {
        var waiting = 0
        let titled = EventRelay.events(for: .notice(title: "Build failed", body: "A header is missing."), waiting: &waiting)
        #expect(titled.count == 1 && titled[0].0 == AgentNoticeRules.eventKind && titled[0].0 == "notice")
        #expect(titled[0].1 == .object(["title": .string("Build failed"), "body": .string("A header is missing.")]))
        let bare = EventRelay.events(for: .notice(title: nil, body: "Unlock the phone."), waiting: &waiting)
        #expect(bare[0].1 == .object(["body": .string("Unlock the phone.")]))
        #expect(waiting == 0)
    }
}
