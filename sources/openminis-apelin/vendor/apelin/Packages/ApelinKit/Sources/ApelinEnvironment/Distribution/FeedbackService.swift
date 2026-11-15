import ApelinProtocol
import Foundation

/// Feedback filed as a public issue on Apelin's own repository
/// (`FeedbackSendRequest`), with the github.com sign-in the user made in
/// Settings ▸ Git. The title and body are checked as `IssueReport` checks
/// every public issue's — against this device's own home, install root and
/// host name too — before the sign-in is looked at, so a refused text
/// reaches nobody, and the footer below it is `IssueReport`'s; nothing the
/// caller sent goes into it. The same sign-in reads an issue there
/// (`FeedbackReadRequest`) and edits one the account opened
/// (`FeedbackEditRequest`), only while it still says what the edit was made
/// against, keeping its footer; it reads whether the account has starred
/// that repository and stars it when the reader asks (`FeedbackStarRequest`).
public struct FeedbackService: Sendable {
    let credentials: any GitCredentialStore
    /// GitHub's API; a test answers for it.
    var exchange: GitHubAPI.Exchange = GitHubAPI.live
    /// The checks and the footer; a test sets the host name and iOS version.
    var report: IssueReport

    public init(layout: EnvironmentLayout, credentials: any GitCredentialStore) {
        self.credentials = credentials
        report = IssueReport(layout: layout)
    }

    public func send(_ request: FeedbackSendRequest) async throws -> FeedbackSendResponse {
        let title = request.title.trimmingCharacters(in: .whitespaces)
        if let problem = report.problem(title: title, body: request.body) {
            throw ApelinError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let issue = try await api.createIssue(
            FeedbackRules.repository,
            title: title,
            body: FeedbackRules.issueBody(request.body, footer: report.footer()),
        )
        return FeedbackSendResponse(number: issue.number, url: issue.htmlURL)
    }

    /// One issue of Apelin's repository, its footer apart, and whether the
    /// sign-in opened it.
    public func read(_ request: FeedbackReadRequest) async throws -> FeedbackReadResponse {
        try Self.checkNumber(request.number)
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let issue = try await feedbackIssue(request.number, api: api)
        let login = try await api.login()
        let body = FeedbackRules.split(issueBody: issue.body ?? "")
        return FeedbackReadResponse(
            number: issue.number,
            url: issue.htmlURL,
            title: issue.title,
            body: body.text,
            footer: body.footer,
            author: Self.author(of: issue),
            state: issue.state,
            isAuthor: Self.author(of: issue).lowercased() == login.lowercased(),
        )
    }

    /// An issue the sign-in opened, edited only while it still says what
    /// the edit was made against; the fields that change alone are sent,
    /// the footer kept below the body as it was.
    public func edit(_ request: FeedbackEditRequest) async throws -> FeedbackEditResponse {
        try Self.checkNumber(request.number)
        let title = request.title.map { $0.trimmingCharacters(in: .whitespaces) }
        let newTitle = title == request.expectedTitle ? nil : title
        let newBody = request.body == request.expectedBody ? nil : request.body
        if let problem = report.editProblem(title: newTitle, body: newBody) {
            throw ApelinError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let issue = try await feedbackIssue(request.number, api: api)
        let login = try await api.login()
        let author = Self.author(of: issue)
        guard author.lowercased() == login.lowercased() else {
            throw ApelinError(
                .denied,
                "#\(request.number) on \(FeedbackRules.repository) was opened by \(author), not by the signed-in account \(login): only an issue the account opened is edited.",
            )
        }
        let current = FeedbackRules.split(issueBody: issue.body ?? "")
        guard issue.title == request.expectedTitle, current.text == request.expectedBody else {
            throw ApelinError(
                .conflict,
                "#\(request.number) on \(FeedbackRules.repository) changed on GitHub since it was read, so nothing was written: read it again and make the edit against what it says now.",
            )
        }
        let edited = try await api.editIssue(
            FeedbackRules.repository,
            number: request.number,
            title: newTitle,
            body: newBody.map(current.replacingText),
        )
        return FeedbackEditResponse(
            number: edited.number,
            url: edited.htmlURL,
            title: edited.title,
            body: FeedbackRules.split(issueBody: edited.body ?? "").text,
        )
    }

    /// Issue `number` of Apelin's repository and nothing else: not a pull
    /// request, and not an issue GitHub moved to another repository, whose
    /// old address it redirects to the new one.
    private func feedbackIssue(_ number: Int, api: GitHubAPI) async throws -> GitHubAPI.IssueDetail {
        let repository = FeedbackRules.repository
        let issue: GitHubAPI.IssueDetail
        do {
            issue = try await api.issue(repository, number: number)
        } catch let error as ApelinError where error.code == .notFound {
            throw ApelinError(.notFound, "\(repository) has no issue #\(number), or the sign-in cannot see it.")
        }
        guard issue.pullRequest == nil else {
            throw ApelinError(.notFound, "#\(number) on \(repository) is a pull request, not an issue.")
        }
        guard issue.number == number,
              issue.htmlURL.lowercased() == "https://github.com/\(repository)/issues/\(number)".lowercased()
        else {
            throw ApelinError(.notFound, "#\(number) is no longer an issue on \(repository): GitHub moved it elsewhere.")
        }
        return issue
    }

    private static func checkNumber(_ number: Int) throws {
        guard number >= 1 else {
            throw ApelinError(.badRequest, "an issue's number is 1 or more")
        }
    }

    /// GitHub's placeholder for an account that is gone stands in for none.
    private static func author(of issue: GitHubAPI.IssueDetail) -> String {
        issue.user?.login ?? "ghost"
    }

    /// Whether the sign-in has starred Apelin's repository.
    public func starState(_: FeedbackStarStateRequest) async throws -> FeedbackStarResponse {
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let starred = try await api.isStarred(FeedbackRules.repository)
        return FeedbackStarResponse(repository: FeedbackRules.repository, starred: starred)
    }

    /// Stars Apelin's repository with the sign-in, as the reader asked.
    public func star(_: FeedbackStarRequest) async throws -> FeedbackStarResponse {
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        try await api.star(FeedbackRules.repository)
        return FeedbackStarResponse(repository: FeedbackRules.repository, starred: true)
    }
}
