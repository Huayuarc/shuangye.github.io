import ApelinProtocol
import Foundation

/// An issue opened on a GitHub repository the user chose
/// (`GitIssueCreateRequest`; owner, 2026-10-30) with the github.com sign-in
/// the user made in Settings ▸ Git: the repository's shape is checked, and
/// the title and body as every public issue's are (`IssueReport`), before
/// the sign-in is read, so a refused one reaches nobody; the footer below
/// the body is `IssueReport`'s. Only the repository the request names is
/// asked, and GitHub's refusals say what blocks it (`GitHubAPI.createIssue`).
public struct GitHubIssueService: Sendable {
    let credentials: any GitCredentialStore
    /// GitHub's API; a test answers for it.
    var exchange: GitHubAPI.Exchange = GitHubAPI.live
    /// The checks and the footer; a test sets the host name and iOS version.
    var report: IssueReport

    public init(layout: EnvironmentLayout, credentials: any GitCredentialStore) {
        self.credentials = credentials
        report = IssueReport(layout: layout)
    }

    public func create(_ request: GitIssueCreateRequest) async throws -> GitIssueCreateResponse {
        if let problem = request.problem {
            throw ApelinError(.badRequest, problem)
        }
        let title = request.title.trimmingCharacters(in: .whitespaces)
        if let problem = report.problem(title: title, body: request.body) {
            throw ApelinError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let issue = try await api.createIssue(
            request.repository,
            title: title,
            body: FeedbackRules.issueBody(request.body, footer: report.footer()),
        )
        return GitIssueCreateResponse(number: issue.number, url: issue.htmlURL, repository: request.repository)
    }
}
