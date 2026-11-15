import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

/// GitHub, answering each request with the next scripted answer, and noting
/// what it was asked and how long the flow waited.
final class FakeGitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    private(set) var waits: [TimeInterval] = []

    init(_ answers: [(Int, String)]) {
        self.answers = answers
    }

    var flow: GitHubDeviceFlow {
        GitHubDeviceFlow(
            exchange: { request in
                let (status, body) = self.lock.withLock {
                    self.requests.append(request)
                    precondition(!self.answers.isEmpty, "asked more than the script answers: \(request)")
                    return self.answers.removeFirst()
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            },
            wait: { seconds in
                self.lock.withLock { self.waits.append(seconds) }
            },
        )
    }

    func form(_ index: Int) -> [String: String] {
        let body = String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
        var form: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            form[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return form
    }
}

let codeAnswer = """
{"device_code":"3584d83530557fdd1f46af8289938c8ef79f9dc5","user_code":"WDJB-MJHT",\
"verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
"""

func expectFailure(_ expected: GitHubDeviceFlow.Failure, line: Int = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        require(false, "expected \(expected)", line: line)
    } catch let failure as GitHubDeviceFlow.Failure {
        require(failure == expected, "expected \(expected), got \(failure)", line: line)
    } catch {
        require(false, "expected \(expected), got \(error)", line: line)
    }
}

/// The code is asked for as gh asks: its client, the scopes, a JSON answer.
let github = FakeGitHub([
    (200, codeAnswer),
    (200, #"{"error":"authorization_pending","error_description":"The authorization request is still pending."}"#),
    (200, #"{"error":"slow_down","interval":10}"#),
    (200, #"{"access_token":"gho_example_not_a_token","token_type":"bearer","scope":"repo,workflow"}"#),
    (200, #"{"login":"octocat","id":1}"#),
])
let code = try await github.flow.requestCode()
require(code.userCode == "WDJB-MJHT" && code.interval == 5 && code.expiresIn == 900, "The code reads")
require(code.verificationURL.absoluteString == "https://github.com/login/device", "The page reads")
require(github.requests[0].url == GitHubDeviceFlow.codeURL && github.requests[0].httpMethod == "POST", "Posted to the code URL")
require(github.requests[0].value(forHTTPHeaderField: "Accept") == "application/json", "A JSON answer")
require(github.form(0) == ["client_id": "178c6fc778ccc68e1d6a", "scope": "repo workflow"], "gh's client and the scopes")

/// Pending goes on, slow_down takes GitHub's interval with a wider margin, a token ends it.
let token = try await github.flow.token(for: code)
require(token == "gho_example_not_a_token", "The token")
require(github.waits == [6, 6, 14], "A fifth over the interval, then two fifths over the new one: \(github.waits)")
require(github.form(1) == [
    "client_id": "178c6fc778ccc68e1d6a",
    "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
], "Each poll names the device code and the grant")
let login = try await github.flow.login(token: token)
require(login == "octocat", "The account's login")
let userRequest = github.requests[4]
require(userRequest.url == GitHubDeviceFlow.userURL && userRequest.httpMethod == "GET", "The user is read")
require(userRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)", "With the token")
print("ok: a device code, polled through pending and slow_down to a token and the account's login")

/// slow_down without an interval adds five seconds.
let slower = FakeGitHub([(200, #"{"error":"slow_down"}"#), (200, #"{"access_token":"t"}"#)])
_ = try await slower.flow.token(for: code)
require(slower.waits == [6, 14], "Five seconds more, two fifths over: \(slower.waits)")

// Declined, expired by GitHub or by time, refused, unreadable.
await expectFailure(.denied) {
    _ = try await FakeGitHub([(200, #"{"error":"access_denied"}"#)]).flow.token(for: code)
}

await expectFailure(.expired) {
    _ = try await FakeGitHub([(200, #"{"error":"expired_token"}"#)]).flow.token(for: code)
}

let brief = GitHubDeviceFlow.Code(userCode: "A", verificationURL: code.verificationURL, deviceCode: "d", expiresIn: 13, interval: 5)
let pending = FakeGitHub(Array(repeating: (200, #"{"error":"authorization_pending"}"#), count: 3))
await expectFailure(.expired) { _ = try await pending.flow.token(for: brief) }
require(pending.waits == [6, 6], "No poll after the code has run out: \(pending.waits)")
await expectFailure(.refused("The client is not enabled for device flow.")) {
    _ = try await FakeGitHub([
        (200, #"{"error":"device_flow_disabled","error_description":"The client is not enabled for device flow."}"#),
    ]).flow.requestCode()
}

await expectFailure(.refused("incorrect_device_code")) {
    _ = try await FakeGitHub([(200, #"{"error":"incorrect_device_code"}"#)]).flow.token(for: code)
}

await expectFailure(.unreadable) {
    _ = try await FakeGitHub([(200, #"{"user_code":"A"}"#)]).flow.requestCode()
}

await expectFailure(.unreadable) {
    _ = try await FakeGitHub([(200, codeAnswer.replacingOccurrences(of: "https://", with: "http://"))]).flow.requestCode()
}

await expectFailure(.refused("HTTP 502")) {
    _ = try await FakeGitHub([(502, "<html>Bad gateway</html>")]).flow.requestCode()
}

await expectFailure(.refused("Bad credentials")) {
    _ = try await FakeGitHub([(401, #"{"message":"Bad credentials"}"#)]).flow.login(token: "t")
}

print("ok: declined, expired, refused and unreadable answers end the sign-in")

require(GitHubDeviceFlow.formBody(["b": "a b&c=d", "a": "é"]) == "a=%C3%A9&b=a%20b%26c%3Dd", "The form is escaped")
print("ok: GitHubDeviceFlow")
