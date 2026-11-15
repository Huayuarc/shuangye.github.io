import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// A candidate key stays in memory until its configured model answers.
/// This runs in the account worker, never in the app or a user conversation.
public enum ProviderKeyVerification {
    public static func verify(
        _ provider: AgentProvider,
        _ credentials: OAuthCredentials,
        modelOverride: String? = nil,
    ) async throws {
        let source = DeliveredCredentialSource([provider.storeID: credentials])
        let cancellation = CancellationHandle()
        do {
            try await AccountDesk.withDeadline(45) {
                try await withTaskCancellationHandler {
                    let manager = OAuthManager(source: source)
                    let model = modelOverride
                        ?? (ProviderModels.isDeepSeek(credentials)
                            ? ProviderModels.list(provider, credentials: credentials).first
                            : nil)
                    guard let resolved = try await ProviderRegistration.resolve(storeID: provider.storeID, manager: manager, modelOverride: model) else {
                        throw ApelinError(.badRequest, "The provider could not be configured.")
                    }
                    let auth = try await resolved.authResolver?(resolved.model, nil)
                    let response = try await complete(
                        model: resolved.model,
                        context: Context(messages: [.user(UserMessage(text: "Reply with OK."))]),
                        options: StreamOptions(
                            maxTokens: 32,
                            maxRetryDelayMs: 0,
                            resolvedAuth: auth,
                            cancellation: cancellation,
                            verbose: false,
                        ),
                    )
                    try Task.checkCancellation()
                    guard response.stopReason == .stop || response.stopReason == .length,
                          response.content.contains(where: {
                              switch $0 {
                              case let .text(text): !text.text.isEmpty
                              case let .thinking(thinking): !thinking.thinking.isEmpty
                              default: false
                              }
                          })
                    else { throw ApelinError(.unavailable, "The provider returned no response.") }
                } onCancel: {
                    cancellation.cancel()
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Provider error bodies may echo submitted values. No response
            // body, key, or request header crosses back to the app.
            throw ApelinError(
                .unavailable,
                "Unable to verify this provider. Check the API key, endpoint and model, then try again.",
            )
        }
    }
}
