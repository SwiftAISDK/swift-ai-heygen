@testable import SwiftAIHeyGen
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

/// @ai-sdk/heygen 3.0.0 heygen-provider.test.ts, with native credential timing.
@Suite struct HeyGenProviderTests {
    @Test func factoriesAliasesAndUnsupportedCapabilities() async throws {
        let p = try heyGenTestProvider(RecordingTransport(response: jsonResponse(heyGenCreated)))
        #expect(p.providerID == "heygen")
        #expect(p.supportedCapabilities == [.video])
        for video in [try p.video("heygen-video-1"), try p.videoModel("heygen-video-1")] {
            let model = try #require(video as? HeyGenVideoModel)
            #expect(model.providerID == "heygen.video")
            #expect(model.modelID == "heygen-video-1")
            #expect(model.maxVideosPerCall == 1)
            #expect(!model.supportsUnaryVideoGeneration)
            #expect(!model.supportsVideoGenerationWebhooks)
        }
        #expect(try p.video("future-model").modelID == "future-model")
        #expect(throws: AIError.unsupportedModel(provider: "heygen", capability: .language, modelID: "other")) { try p.languageModel("other") }
        #expect(throws: AIError.unsupportedModel(provider: "heygen", capability: .embedding, modelID: "other")) { try p.embeddingModel("other") }
        #expect(throws: AIError.unsupportedModel(provider: "heygen", capability: .image, modelID: "other")) { try p.imageModel("other") }
    }

    @Test(arguments: [true, false]) func explicitAndEnvironmentCredentialsCustomEndpointHeaders(_ explicit: Bool) async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"data":{"status":"pending"}}"#, headers: ["x-response": "ready"]))
        let p = try AIProviders.heyGen(configuration: HeyGenProviderSettings(
            apiKey: explicit ? "explicit-key" : nil, baseURL: "https://proxy.example.com/heygen/",
            headers: ["X-Custom": "custom", "User-Agent": "App/1.0"],
            environment: ["HEYGEN_API_KEY": "env-key"], transport: transport
        ))
        _ = try await AI.getVideoStatus(model: p.video("heygen-video-1"), operation: heyGenOperation, headers: ["X-Request": "request"], retryPolicy: .none)
        let call = try #require(await transport.requests().first)
        #expect(call.url.absoluteString == "https://proxy.example.com/heygen/v3/models/videos/video-1")
        #expect(call.method == "GET")
        #expect(call.headers["x-api-key"] == (explicit ? "explicit-key" : "env-key"))
        #expect(call.headers["x-custom"] == "custom")
        #expect(call.headers["x-request"] == "request")
        #expect(call.headers["user-agent"] == "App/1.0 ai-sdk-heygen/3.0.10")
    }

    @Test func nativeFactoryReportsMissingCredentials() {
        #expect(throws: AIError.missingAPIKey(provider: "heygen", environmentVariables: ["HEYGEN_API_KEY"])) {
            try AIProviders.heyGen(configuration: HeyGenProviderSettings(environment: [:]))
        }
    }

    @Test func headerOverridesAreCaseInsensitive() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"data":{"status":"pending"}}"#))
        let p = try heyGenTestProvider(transport, headers: ["X-API-Key": "provider-key"])
        _ = try await AI.getVideoStatus(model: p.video("heygen-video-1"), operation: heyGenOperation, retryPolicy: .none)
        _ = try await AI.getVideoStatus(model: p.video("heygen-video-1"), operation: heyGenOperation, headers: ["X-Api-Key": "call-key"], retryPolicy: .none)
        let calls = await transport.requests()
        #expect(calls[0].headers["x-api-key"] == "provider-key")
        #expect(calls[1].headers["x-api-key"] == "call-key")
        #expect(calls[1].headers.keys.filter { $0.lowercased() == "x-api-key" }.count == 1)
    }

    @Test func statusRedirectStripsCredentialsAndCustomSecrets() async throws {
        let transport = RecordingTransport(responses: [
            AIHTTPResponse(statusCode: 302, headers: ["location": "https://cdn.example.com/status"]),
            jsonResponse(#"{"data":{"status":"pending"}}"#)
        ])
        let p = try heyGenTestProvider(transport, headers: ["X-Custom-Secret": "secret"])
        _ = try await AI.getVideoStatus(model: p.video("heygen-video-1"), operation: heyGenOperation, headers: ["X-Call-Secret": "call-secret"], retryPolicy: .none)
        let calls = await transport.requests()
        #expect(calls[0].headers["x-api-key"] == "test-key")
        #expect(calls[1].headers.keys.allSatisfy { $0.lowercased() == "user-agent" })
        #expect(calls.allSatisfy { !$0.followRedirects })
    }

    @Test func statusRejectsRedirectToPrivateAddress() async throws {
        let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 302, headers: ["location": "https://127.0.0.1/status"]))
        await #expect(throws: AIError.invalidArgument(
            argument: "url", message: "URL with IP address 127.0.0.1 is not allowed."
        )) {
            try await AI.getVideoStatus(model: heyGenTestProvider(transport).video("heygen-video-1"), operation: heyGenOperation, retryPolicy: .none)
        }
        #expect(await transport.requests().count == 1)
    }
}
