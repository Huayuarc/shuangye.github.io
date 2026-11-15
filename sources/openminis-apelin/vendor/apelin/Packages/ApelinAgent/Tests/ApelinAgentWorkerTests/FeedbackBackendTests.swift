import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_feedback_send is one feedbackSend request")
struct FeedbackBackendTests {
    @Test
    func `the issue goes as feedbackSend with its title and body alone`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.feedbackSend, reply: FeedbackSendResponse(number: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12"))
        let response = try await fixture.backend.sendFeedback(FeedbackToolRequest(
            context: fixture.context(),
            title: "The build log stops early",
            body: "It ends before the link step.",
        ))
        let sent = try #require(fixture.host.requests(FeedbackSendRequest.self).first)
        #expect(fixture.host.requests.map(\.operation) == [.feedbackSend])
        #expect(sent.title == "The build log stops early" && sent.body == "It ends before the link step.")
        #expect(response == FeedbackToolResponse(repository: "owngoal-dev/Apelin", issue: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12"))
    }

    @Test
    func `without a GitHub sign-in it names Sign In with GitHub, by the reply's reason`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.feedbackSend) { _ in
            throw ApelinError(.denied, "no sign-in", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await fixture.backend.sendFeedback(FeedbackToolRequest(context: fixture.context(), title: "T", body: "B"))
        } throws: { error in
            let message = (error as? FeedbackToolFailure)?.message ?? ""
            return message.contains("GitHub authorization is needed") && message.contains("Sign In with GitHub in Settings ▸ Git")
                && message.contains("Nothing was posted")
        }

        // Another refusal is the host's own, whatever its words say.
        fixture.host.on(.feedbackSend) { _ in
            throw ApelinError(.denied, "approval required: GitHub authorization was not given")
        }
        await #expect {
            _ = try await fixture.backend.sendFeedback(FeedbackToolRequest(context: fixture.context(), title: "T", body: "B"))
        } throws: { error in
            (error as? ApelinError)?.message.hasPrefix("approval required") == true
        }
    }

    @Test
    func `a read is one feedbackRead, its revision named from the title and body`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.feedbackRead, reply: FeedbackReadResponse(
            number: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12", title: "T", body: "B",
            footer: "Sent with Apelin 0.2.7 (18) · iOS 17.3.1 · rootless", author: "someone", state: "open", isAuthor: true,
        ))
        let read = try await fixture.backend.readFeedback(FeedbackReadToolRequest(context: fixture.context(), number: 12))
        #expect(fixture.host.requests.map(\.operation) == [.feedbackRead])
        #expect(fixture.host.requests(FeedbackReadRequest.self).first?.number == 12)
        #expect(read.repository == "owngoal-dev/Apelin" && read.issue == 12 && read.openedByUser)
        #expect(read.body == "B" && read.footer?.hasPrefix("Sent with Apelin") == true)
        func revision(title: String, body: String) -> String {
            FeedbackReadToolResponse(
                repository: "owngoal-dev/Apelin", issue: 12, url: "", title: title, state: "closed", author: "other",
                openedByUser: false, body: body, footer: nil,
            ).revision
        }
        #expect(read.revision == revision(title: "T", body: "B"), "the text alone names it")
        #expect(read.revision != revision(title: "T", body: "B "), "any change to the text is another revision")
        #expect(read.revision != revision(title: "T ", body: "B"))
    }

    @Test
    func `an edit is one feedbackEdit with what changes and what it was made against`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.feedbackEdit, reply: FeedbackEditResponse(
            number: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12", title: "T", body: "New",
        ))
        let edited = try await fixture.backend.editFeedback(FeedbackEditToolRequest(
            context: fixture.context(), number: 12, title: nil, body: "New", expectedTitle: "T", expectedBody: "B",
        ))
        let sent = try #require(fixture.host.requests(FeedbackEditRequest.self).first)
        #expect(fixture.host.requests.map(\.operation) == [.feedbackEdit])
        #expect(sent.number == 12 && sent.title == nil && sent.body == "New")
        #expect(sent.expectedTitle == "T" && sent.expectedBody == "B")
        #expect(edited == FeedbackEditToolResponse(
            repository: "owngoal-dev/Apelin", issue: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12", changed: ["body"],
            title: "T", body: "New",
        ), "the revision an edit after it passes is the text GitHub now has")
        let reread = FeedbackReadToolResponse(
            repository: "owngoal-dev/Apelin", issue: 12, url: "", title: "T", state: "open", author: "someone",
            openedByUser: true, body: "New", footer: nil,
        )
        #expect(edited.revision == reread.revision)

        fixture.host.on(.feedbackEdit) { _ in
            throw ApelinError(.denied, "no sign-in", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await fixture.backend.editFeedback(FeedbackEditToolRequest(
                context: fixture.context(), number: 12, title: "T2", body: nil, expectedTitle: "T", expectedBody: "B",
            ))
        } throws: { error in
            let message = (error as? FeedbackToolFailure)?.message ?? ""
            return message.hasPrefix("Nothing was changed") && message.contains("Sign In with GitHub in Settings ▸ Git")
        }
    }

    @Test
    func `the approval carries the edit the host matches, with no field that stays`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_feedback_edit", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Replaces the body of issue #12.",
            detail: .feedbackEdit(FeedbackEditApproval(
                repository: "owngoal-dev/Apelin", number: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12",
                title: nil, body: "New", currentTitle: "T", currentBody: "B",
            )),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["feedbackEdit": .object([
            "repository": .string("owngoal-dev/Apelin"), "number": .number(12),
            "url": .string("https://github.com/owngoal-dev/Apelin/issues/12"),
            "body": .string("New"), "currentTitle": .string("T"), "currentBody": .string("B"),
        ])])
        #expect(payload["detail"] == expected)
        #expect(payload["allowsSessionScope"] == .bool(false))
    }

    @Test
    func `the approval carries the issue the host matches`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_feedback_send", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Posts this title and body as a public issue.",
            detail: .feedback(FeedbackApproval(repository: "owngoal-dev/Apelin", title: "T", body: "B")),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["feedback": .object([
            "repository": .string("owngoal-dev/Apelin"), "title": .string("T"), "body": .string("B"),
        ])])
        #expect(payload["detail"] == expected)
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
