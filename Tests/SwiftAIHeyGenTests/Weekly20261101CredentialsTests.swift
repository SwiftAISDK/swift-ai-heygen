import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIHeyGen

private actor WeeklyCredentialSequence {
    private(set) var count = 0
    func next() -> String { count += 1; return "rotating-\(count)" }
}
private actor WeeklyCredentialProbe: AITransport {
    private(set) var requests: [AIHTTPRequest] = []
    struct Sent: Error {}
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        throw Sent()
    }
}

@Suite("Weekly20261101 heygen credentials")
struct Weekly20261101CredentialsTests {
    @Test func resolvesFreshCredentialOnlyWhenRequestIsSent() async throws {
        let sequence = WeeklyCredentialSequence()
        let transport = WeeklyCredentialProbe()
        let provider = try HeyGenProvider(configuration: HeyGenProviderSettings(apiKeyProvider: { await sequence.next() }, transport: transport))
        let model = try #require(try provider.videoModel("heygen-video-1") as? any AsyncVideoModel)
        #expect(await sequence.count == 0)
        for _ in 0..<2 { _ = try? await model.startVideoGeneration(.init(request: VideoGenerationRequest(prompt: "Hello"))) }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(await sequence.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.headers.values.contains(where: { $0.contains("rotating-\(index + 1)") }))
            #expect(!request.headers.values.contains(where: { $0.contains("__swift_ai_credential_") }))
        }
    }
}
