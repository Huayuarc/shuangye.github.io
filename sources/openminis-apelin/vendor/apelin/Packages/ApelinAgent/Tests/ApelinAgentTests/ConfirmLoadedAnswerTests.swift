@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// What the model reads from apelin_package_confirm_loaded. On an iOS 17
/// device it read `imageLoaded: false` beside a note about the iOS 27
/// kernel, and no `loaded` at all: the verdict was a computed property the
/// encoder skipped.
@Suite("apelin_package_confirm_loaded's answer")
struct ConfirmLoadedAnswerTests {
    @Test
    func `carries the host's verdict and what it rests on, and no image fields`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (result, asked) = try await harness.run(.packageConfirmLoaded, ["build_id": "build-1", "target": "SpringBoard"])
        #expect(asked.isEmpty, "without a respring it is a read")
        let text = result.content.compactMap {
            if case let .text(text) = $0 {
                text.text
            } else {
                nil
            }
        }.joined()
        let answer = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text)")
        #expect(answer.keys.sorted() == ["basis", "filterMatches", "loaded", "logEvidence", "markerLogged", "notes"])
        #expect(answer["loaded"] as? Bool == true)
        #expect(answer["basis"] as? String == ConfirmLoadedResponse.markerBasis)
        #expect(ConfirmLoadedResponse.markerBasis.range(of: #"iOS \d"#, options: .regularExpression) == nil)
    }
}
