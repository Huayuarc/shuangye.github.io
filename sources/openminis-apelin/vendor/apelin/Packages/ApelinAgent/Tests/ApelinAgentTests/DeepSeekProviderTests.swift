@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("DeepSeek registration and image requests", .serialized)
struct DeepSeekProviderTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

    @Test
    func `DeepSeek has independent credentials and defaults to the vision catalog model`() async throws {
        let source = DeliveredCredentialSource([
            CredentialProviderID.openAICompatible: OAuthCredentials(access: "other-key", refresh: "", expires: .max),
        ])
        let configuration = ProviderConfiguration.stored(storeID: CredentialProviderID.deepSeek, model: nil)
        await #expect(throws: ProviderResolutionError.missingCredentials(CredentialProviderID.deepSeek)) {
            _ = try await ProviderResolver.resolve(configuration, credentials: source)
        }
        let key = OAuthCredentials(access: "deepseek-key", refresh: "", expires: .max)
        await source.store(key, for: CredentialProviderID.deepSeek)
        let resolved = try await ProviderResolver.resolve(configuration, credentials: source)
        #expect(resolved.credentials == key)
        #expect(resolved.model == ModelsCatalog.model(provider: "deepseek", id: "deepseek-flash"))
        #expect(resolved.model.input.contains(.image))
        #expect(resolved.model.reasoning)
        #expect(resolved.model.compat?.thinkingFormat == "deepseek")
    }

    @Test(arguments: ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"])
    func `official compatible accounts retain Flash capabilities and the selected routing`(id: String) async throws {
        let base = "https://api.deepseek.com/v1"
        let key = OAuthCredentials(access: "key", refresh: "", expires: .max, extras: ["baseUrl": .string(base)])
        let source = DeliveredCredentialSource([CredentialProviderID.openAICompatible: key])
        let resolved = try await ProviderResolver.resolve(.openAICompatible(model: id), credentials: source)
        #expect(resolved.model.id == id)
        #expect(resolved.model.provider == "openai-compatible")
        #expect(resolved.model.baseURL == base)
        #expect(resolved.model.input == [.text, .image])
        #expect(resolved.model.thinkingLevelMap == ModelsCatalog.model(provider: "deepseek", id: "deepseek-flash")?.thinkingLevelMap)
    }

    @Test
    func `unknown IDs, text models and unrelated endpoints are not granted vision`() async throws {
        for (base, id) in [
            ("https://api.deepseek.com", "deepseek-v4-pro"),
            ("https://api.deepseek.com", "unknown-model"),
            ("https://api.deepseek.com.example.org/v1", "deepseek-flash"),
            ("https://example.org/v1", "deepseek-flash"),
        ] {
            let source = DeliveredCredentialSource([CredentialProviderID.openAICompatible:
                    OAuthCredentials(access: "key", refresh: "", expires: .max, extras: ["baseUrl": .string(base)])])
            let resolved = try await ProviderResolver.resolve(.openAICompatible(model: id), credentials: source)
            #expect(resolved.model.input == [.text])
            #expect(resolved.model.baseURL == base)
        }
    }

    @Test(arguments: [CredentialProviderID.deepSeek, CredentialProviderID.openAICompatible])
    func `user and tool images reach the Chat Completions request after resolution`(storeID: String) async throws {
        let key = OAuthCredentials(access: "key", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com"),
        ])
        let source = DeliveredCredentialSource([storeID: key])
        let resolved = try await ProviderResolver.resolve(.stored(storeID: storeID, model: "deepseek-flash"), credentials: source)
        let image = ImageContent(data: Self.png, mimeType: "image/png")
        let context = Context(messages: [
            .user(UserMessage(content: [.text(TextContent(text: "Read these screenshots.")), .image(image), .image(image)])),
            .assistant(fauxAssistantMessage(blocks: [fauxToolCall(name: "capture", arguments: [:], id: "capture-1")], stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "capture-1", toolName: "capture", content: [.image(image)])),
            .user(UserMessage(text: "Compare them.")),
        ])
        let client = ImageRequestCapture()
        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "another-account-key")
        let stream = provider.stream(model: resolved.model, context: context, options: StreamOptions(maxTokens: 32, resolvedAuth: auth, verbose: false))
        for await _ in stream {}
        #expect(await stream.result().stopReason == .stop)
        let request = try #require(await client.request)
        #expect(request.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer key")
        let data = try #require(request.body)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let images = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "image_url" }
        #expect(images.count == 3)
        #expect(images.allSatisfy { ($0["image_url"] as? [String: String])?["url"] == "data:image/png;base64," + Self.png })
        #expect(!String(decoding: data, as: UTF8.self).contains("image omitted"))
        #expect(root["model"] as? String == "deepseek-flash")
    }
}

private actor ImageRequestCapture: HTTPClient {
    struct Request: Sendable {
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    var request: Request?

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation _: CancellationHandle?,
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        #expect(method == "POST")
        request = Request(url: url, headers: headers, body: body)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type": "text/event-stream"]))
        let reply = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(Data(reply.utf8))
            continuation.finish()
        })
    }
}
