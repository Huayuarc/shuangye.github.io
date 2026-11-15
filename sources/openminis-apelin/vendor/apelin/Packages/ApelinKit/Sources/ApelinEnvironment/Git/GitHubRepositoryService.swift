import ApelinCore
import ApelinProtocol
import Foundation

/// An empty repository made on GitHub (`GitRepositoryCreateRequest`) with
/// the github.com sign-in the user made in Settings ▸ Git, on that account
/// or in an organization, for a project to push to. The request is checked
/// before the sign-in is read, so a refused one reaches nobody; GitHub's own
/// refusals keep its words.
public struct GitHubRepositoryService: Sendable {
    let credentials: any GitCredentialStore
    /// GitHub's API; a test answers for it.
    var exchange: GitHubAPI.Exchange = GitHubAPI.live

    public init(credentials: any GitCredentialStore) {
        self.credentials = credentials
    }

    public func create(_ request: GitRepositoryCreateRequest) async throws -> GitRepositoryCreateResponse {
        if let problem = request.problem {
            throw ApelinError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        // The account's own login is the account, as the package
        // repository's create takes it; any other owner is an organization.
        var organization: String?
        if let owner = request.owner, try await owner.lowercased() != api.login().lowercased() {
            organization = owner
        }
        let created: GitHubAPI.Repository
        do {
            created = try await api.createRepository(
                name: request.name,
                description: request.description,
                isPrivate: request.visibility == .private,
                organization: organization,
            )
        } catch let error as ApelinError where error.code == .notFound {
            // GitHub answers an organization it will not show the account
            // with a 404, which names no repository here.
            guard let organization else { throw error }
            throw ApelinError(.notFound, "GitHub has no organization \(organization) that the signed-in account can create repositories in.")
        }
        return GitRepositoryCreateResponse(fullName: created.fullName, cloneURL: created.cloneURL, url: created.htmlURL)
    }
}
