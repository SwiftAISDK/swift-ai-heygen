import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
import SwiftAIHeyGen

@Suite("HeyGen Decision native integration")
struct HeyGenDecisionNativeTests {
    @Test func preservesPrimitiveStateAndAssetBoundaries() async throws {
        let values: [JSONValue] = [.null, 2, true, "text", [1, 2], ["object": true]]
        for value in values {
            let (model, transport, _) = try heyGenDecisionSetup()
            var options = heyGenDecisionOptions(); options.state = [.json(value)]
            _ = try await model.doDecide(options)
            let state = try await heyGenTestRequestBody(transport)["state"]
            switch value { case .null, .number, .bool: #expect(state == .array([value])); default: #expect(state == value) }
        }
        let (model, transport, _) = try heyGenDecisionSetup()
        var options = heyGenDecisionOptions()
        options.state = Array(repeating: .file(mediaType: "image/png", data: .base64("iVBORw0KGgo=")), count: 4)
        options.state.append(.file(mediaType: "video/mp4", data: .reference("video-asset")))
        _ = try await model.doDecide(options)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["state"] == [])
        #expect(body["assets"]?["images"]?.objectValue?.count == 4)
        #expect(body["assets"]?["videos"]?["video-1"] == ["type": "asset_id", "asset_id": "video-asset"])
    }

    @Test func propagatesAbortAndDeferredMissingCredentialsWithoutIO() async throws {
        let (model, transport, _) = try heyGenDecisionSetup()
        let controller = AIAbortController()
        var options = heyGenDecisionOptions(); options.abortSignal = controller.signal
        _ = try await model.doDecide(options)
        #expect(await transport.requests().first?.abortSignal === controller.signal)
        controller.abort(reason: "cancelled")
        await #expect(throws: AIAbortError(reason: "cancelled")) { try await model.doDecide(options) }
        #expect(await transport.requests().count == 1)
        let emptyTransport = RecordingTransport(response: jsonResponse("{}"))
        let missing = try createHeyGen(configuration: .init(environment: [:], transport: emptyTransport)).decisionModel("heygen-decision-1")
        await #expect(throws: AIError.missingAPIKey(provider: "heygen", environmentVariables: ["HEYGEN_API_KEY"])) {
            try await missing.doDecide(heyGenDecisionOptions())
        }
        #expect(await emptyTransport.requests().isEmpty)
    }

    @Test func validatesNullableMetadataAndPreservesStructuredScoreLegends() async throws {
        let body = heyGenDecisionReplacingAnswer("impact", with: ["type": "score", "score": 1.75,
            "probabilities": ["0": 0.05, "1": 0.15, "2": 0.8], "legend": ["0": ["severity": "minor"], "1": .null],
            "confidence": .null, "warning": .null])
        let result = try await heyGenDecisionSetup(body: body).model.doDecide(heyGenDecisionOptions())
        #expect(result.providerMetadata["heygen"]?["legend"]?["impact"] == ["0": ["severity": "minor"], "1": .null])
        #expect(result.providerMetadata["heygen"]?["confidence"]?["impact"] == nil)
        #expect(result.providerMetadata["heygen"]?["answerWarnings"] == [:])
        let invalid = heyGenDecisionReplacingAnswer("team", with: ["type": "choice", "choice": "video",
            "probabilities": ["video": 1], "confidence": 2])
        await #expect(throws: AIError.self) { try await heyGenDecisionSetup(body: invalid).model.doDecide(heyGenDecisionOptions()) }
        let fractional = try await heyGenDecisionSetup(body: heyGenDecisionReplacingData("usage", with: ["input_tokens": 1.5, "output_tokens": .null])).model.doDecide(heyGenDecisionOptions())
        #expect(fractional.usage == .init(inputTokens: nil, outputTokens: nil))
        #expect(fractional.response?.body?["data"]?["usage"]?["input_tokens"] == 1.5)
    }

    @Test func exposesDecisionCatalogAndRetainsVideoFactory() throws {
        let (_, _, provider) = try heyGenDecisionSetup()
        #expect(provider.supportedCapabilities == [.decision, .video])
        #expect(try provider.videoModel("heygen-video-1").modelID == "heygen-video-1")
        #expect(try provider.decision("future-decision").modelID == "future-decision")
        #expect(try heygen.decisionModel("heygen-decision-1").providerID == "heygen.decision")
        #expect(HeyGenDecisionModelOptions().providerOptions == ["heygen": [:]])
        #expect(heyGenDecisionModelIDs == ["heygen-decision-1", "heygen-decision-1-turbo"])
        #expect(heyGenDecisionModelLimits.maxQuestions == 400)
        #expect(heyGenDecisionModelLimits.maxChoiceOptions == 255)
        #expect(heyGenDecisionModelLimits.maxScoreLevels == 10)
        #expect(heyGenDecisionModelLimits.maxImages == 4)
        #expect(heyGenDecisionModelLimits.maxVideos == 1)
        #expect(getHeyGenDecisionModelEntry("custom").capabilities.decision?.inputs.image == .supported)
    }
}
