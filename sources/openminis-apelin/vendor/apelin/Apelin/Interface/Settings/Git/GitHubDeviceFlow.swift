import Foundation

/// GitHub's OAuth device flow, as `gh auth login` runs it (cli/cli
/// `internal/authflow`, cli/oauth `device`), for the HTTPS credential of
/// github.com: GitHub hands out a code, the user enters it at
/// github.com/login/device and approves, and the token endpoint, polled
/// meanwhile, answers a token. Each poll waits a fifth longer than the
/// interval GitHub gave, as gh does for clocks that run fast; a `slow_down`
/// takes GitHub's new interval (five seconds more without one) and a margin
/// of two fifths. The token is gh's default kind, which never expires and
/// comes with no refresh token, and the account's login, read with it, is
/// the user name the credential is saved under.
///
/// It runs in the app, which has the network; the token then goes to
/// apelin-environment's keychain through `gitCredentialSet`, as a typed one
/// does, and nowhere else. The client is GitHub CLI's OAuth app — gh ships
/// its ID in the open and the device flow needs no secret — so GitHub's page
/// asks the user to authorize GitHub CLI, which the page says first.
struct GitHubDeviceFlow: Sendable {
    /// The "GitHub CLI" OAuth app (cli/cli `internal/authflow/flow.go`).
    static let clientID = "178c6fc778ccc68e1d6a"
    /// Clone, fetch and push any repository the account reaches, and push
    /// a change under `.github/workflows`, which `repo` alone is refused.
    static let scopes = ["repo", "workflow"]
    static let host = "github.com"
    static let codeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let userURL = URL(string: "https://api.github.com/user")!
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    struct Code: Equatable, Sendable {
        /// What the user types on GitHub's page, `XXXX-XXXX`.
        let userCode: String
        let verificationURL: URL
        let deviceCode: String
        let expiresIn: TimeInterval
        let interval: TimeInterval
    }

    enum Failure: Error, Equatable {
        /// The user declined on GitHub's page.
        case denied
        /// The code ran out before it was approved.
        case expired
        /// GitHub said no, in its words when it gave any.
        case refused(String)
        /// An answer that does not read as GitHub's.
        case unreadable
    }

    /// One HTTPS exchange; the harness answers for GitHub.
    let exchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Waits between polls; the harness only notes how long.
    let wait: @Sendable (TimeInterval) async throws -> Void

    static let live = GitHubDeviceFlow(
        exchange: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unreadable }
            return (data, response)
        },
        wait: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
    )

    /// Asks GitHub for a code.
    func requestCode() async throws -> Code {
        let answer = try await post(Self.codeURL, [
            "client_id": Self.clientID,
            "scope": Self.scopes.joined(separator: " "),
        ])
        if let error = answer.object["error"] as? String {
            throw Failure.refused(answer.object["error_description"] as? String ?? error)
        }
        guard answer.status == 200,
              let userCode = answer.object["user_code"] as? String, !userCode.isEmpty,
              let deviceCode = answer.object["device_code"] as? String, !deviceCode.isEmpty,
              let page = (answer.object["verification_uri"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https",
              let expiresIn = answer.object["expires_in"] as? Double,
              let interval = answer.object["interval"] as? Double
        else { throw Failure.unreadable }
        return Code(
            userCode: userCode,
            verificationURL: page,
            deviceCode: deviceCode,
            expiresIn: expiresIn,
            interval: max(interval, 1),
        )
    }

    /// Polls until the user approves, declines or the code runs out.
    func token(for code: Code) async throws -> String {
        var interval = code.interval
        var margin = 1.2
        var waited: TimeInterval = 0
        while true {
            let pause = interval * margin
            guard waited + pause < code.expiresIn else { throw Failure.expired }
            try await wait(pause)
            waited += pause
            let answer = try await post(Self.tokenURL, [
                "client_id": Self.clientID,
                "device_code": code.deviceCode,
                "grant_type": Self.grantType,
            ])
            if let token = answer.object["access_token"] as? String, !token.isEmpty {
                return token
            }
            switch answer.object["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                // RFC 8628 § 3.5: five seconds more, unless GitHub says how long
                interval = (answer.object["interval"] as? Double).map { max($0, 1) } ?? interval + 5
                margin = 1.4
            case "expired_token":
                throw Failure.expired
            case "access_denied":
                throw Failure.denied
            case let error?:
                throw Failure.refused(answer.object["error_description"] as? String ?? error)
            case nil:
                throw Failure.unreadable
            }
        }
    }

    /// The login of the account the token is for: the credential's user name.
    func login(token: String) async throws -> String {
        var request = URLRequest(url: Self.userURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await exchange(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard response.statusCode == 200 else {
            throw Failure.refused(object["message"] as? String ?? "HTTP \(response.statusCode)")
        }
        guard let login = object["login"] as? String, !login.isEmpty else { throw Failure.unreadable }
        return login
    }

    /// A form posted for a JSON answer, as GitHub's OAuth endpoints take it.
    private func post(_ url: URL, _ form: [String: String]) async throws -> (status: Int, object: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formBody(form).utf8)
        let (data, response) = try await exchange(request)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw response.statusCode == 200 ? Failure.unreadable : Failure.refused("HTTP \(response.statusCode)")
        }
        return (response.statusCode, object)
    }

    /// `application/x-www-form-urlencoded`, keys in order, everything but
    /// letters, digits and `-._~` escaped.
    static func formBody(_ form: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return form.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
    }
}
