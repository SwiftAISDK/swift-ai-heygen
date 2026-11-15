import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIHeyGen

@Suite("HeyGen Decision matching-release request contract")
struct HeyGenDecisionRequestUpstreamTests {
    @Test func sendsOneNativeRequestWithAllQuestionTypesAndConfiguredHeaders() async throws {
        let (model, transport, _) = try heyGenDecisionSetup()
        var options = heyGenDecisionOptions(); options.headers = ["shared": "call"]
        _ = try await model.doDecide(options)
        #expect(model.specificationVersion == "v4")
        #expect(model.providerID == "heygen.decision")
        #expect(model.modelID == "heygen-decision-1")
        #expect(model.supportedQuestionTypes == [.choice, .score, .boolean])
        let requests = await transport.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url.absoluteString == "https://example.com/v3/models/decisions")
        #expect(request.headers["x-api-key"] == "test-key")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["x-provider"] == "custom")
        #expect(request.headers["shared"] == "call")
        #expect(request.headers["user-agent"]?.contains("ai-sdk-heygen/3.0.25") == true)
        #expect(try await heyGenTestRequestBody(transport) == [
            "model": "heygen-decision-1", "state": "Video export fails for everyone.",
            "questions": [
                "blocked": ["type": "noul", "instructions": "Is the customer unable to work?"],
                "team": ["type": "choice", "instructions": "Which team should handle this request?", "criteria": ["video": "Rendering", "account": "Access", "billing": "Payments"]],
                "impact": ["type": "score", "instructions": "How much does this affect the customer?", "criteria": ["Cosmetic", "Slower", "Blocked"]]
            ]
        ])
    }

    @Test func sendsOrderedImageVideoAssetsAndKeepsTextAndJSONInState() async throws {
        let (model, transport, _) = try heyGenDecisionSetup(body: ["data": ["answers": ["blocked": heyGenDecisionFixture["data"]!["answers"]!["blocked"]!]]])
        let options = AIDecisionModelV4CallOptions(state: [
            .text("Compare the first image with the video."),
            .file(mediaType: "image", data: .data(Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))),
            .file(mediaType: "video/mp4", data: .url(URL(string: "https://example.com/clip.mp4")!)),
            .file(mediaType: "image/jpeg", data: .reference("asset-123")),
            .json(["product": "vase"])
        ], questions: ["blocked": heyGenDecisionQuestions["blocked"]!])
        _ = try await model.doDecide(options)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["state"] == ["Compare the first image with the video.", ["product": "vase"]])
        #expect(body["assets"] == [
            "images": ["image-1": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="],
                       "image-2": ["type": "asset_id", "asset_id": "asset-123"]],
            "videos": ["video-1": ["type": "url", "url": "https://example.com/clip.mp4"]]
        ])
    }

    static let invalidStates: [[AIDecisionStatePart]] = [
        Array(repeating: .file(mediaType: "image/png", data: .base64("iVBORw0KGgo=")), count: 5),
        Array(repeating: .file(mediaType: "video/mp4", data: .url(URL(string: "https://example.com/a.mp4")!)), count: 2),
        [.file(mediaType: "image/png", data: .url(URL(string: "http://example.com/a.png")!))],
        [.file(mediaType: "image", data: .data(Data([1, 2, 3])))],
        [.file(mediaType: "application/pdf", data: .base64("JVBERi0="))]
    ]

    @Test(arguments: Array(invalidStates.indices))
    func rejectsInvalidMediaBeforeHTTP(_ index: Int) async throws {
        let (model, transport, _) = try heyGenDecisionSetup()
        var options = heyGenDecisionOptions(); options.state = Self.invalidStates[index]
        if index == 4 {
            await #expect(throws: AIDecisionUnsupportedFunctionalityError(functionality: "HeyGen decision file media type: application/pdf")) {
                try await model.doDecide(options)
            }
        } else {
            do { _ = try await model.doDecide(options); Issue.record("Expected invalid argument") }
            catch let error as AIError { guard case .invalidArgument = error else { Issue.record("Unexpected error: \(error)"); return } }
        }
        #expect(await transport.requests().isEmpty)
    }

    static let invalidQuestions: [[String: AIDecisionQuestion]] = [
        [:], ["": heyGenDecisionQuestions["blocked"]!], [" padded": heyGenDecisionQuestions["blocked"]!],
        ["a:b": heyGenDecisionQuestions["blocked"]!], ["a\nb": heyGenDecisionQuestions["blocked"]!],
        Dictionary(uniqueKeysWithValues: (0..<401).map { (String($0), heyGenDecisionQuestions["blocked"]!) }),
        ["team": .choice(instructions: "Which team should handle this request?", criteria: [:])],
        ["team": .choice(instructions: "Which team should handle this request?", criteria: Dictionary(uniqueKeysWithValues: (0..<256).map { (String($0), .null) }))],
        ["impact": .score(instructions: "How much does this affect the customer?", criteria: [])],
        ["impact": .score(instructions: "How much does this affect the customer?", criteria: ["Low", .null])],
        ["impact": .score(instructions: "How much does this affect the customer?", criteria: (0..<11).map { .string(String($0)) })]
    ]

    @Test(arguments: invalidQuestions)
    func rejectsInvalidProviderLimitsBeforeHTTP(_ questions: [String: AIDecisionQuestion]) async throws {
        let (model, transport, _) = try heyGenDecisionSetup()
        var options = heyGenDecisionOptions(); options.questions = questions
        do { _ = try await model.doDecide(options); Issue.record("Expected invalid argument") }
        catch let error as AIError { guard case .invalidArgument = error else { Issue.record("Unexpected error: \(error)"); return } }
        #expect(await transport.requests().isEmpty)
    }

    @Test func acceptsMaximumQuestionCountAndSingleLevelScore() async throws {
        var questions = Dictionary(uniqueKeysWithValues: (0..<399).map { (String($0), heyGenDecisionQuestions["blocked"]!) })
        questions["single"] = .score(instructions: "Rate", criteria: ["Only"])
        var answers = Dictionary(uniqueKeysWithValues: (0..<399).map { (String($0), heyGenDecisionFixture["data"]!["answers"]!["blocked"]!) })
        answers["single"] = ["type": "score", "score": 0, "probabilities": ["0": 1]]
        let (model, transport, _) = try heyGenDecisionSetup(body: ["data": ["answers": .object(answers)]])
        var options = heyGenDecisionOptions(); options.questions = questions
        _ = try await model.doDecide(options)
        #expect(await transport.requests().count == 1)
        #expect(try await heyGenTestRequestBody(transport)["questions"]?.objectValue?.count == 400)
    }

    @Test func rejectsBoxQuestionsBeforeHTTP() async throws {
        let (model, transport, _) = try heyGenDecisionSetup()
        var options = heyGenDecisionOptions(); options.questions = ["box": .box(instructions: "Find the product")]
        await #expect(throws: AIDecisionUnsupportedQuestionTypeError.self) { try await model.doDecide(options) }
        #expect(await transport.requests().isEmpty)
    }

    @Test func warnsUnsupportedSettingsWithoutSendingFields() async throws {
        let (model, transport, _) = try heyGenDecisionSetup()
        var options = heyGenDecisionOptions(); options.maxOutputTokens = 10; options.reasoning = "low"
        options.providerOptions = ["heygen": ["temperature": 0]]
        let result = try await model.doDecide(options)
        #expect(result.warnings == [.init(type: "unsupported", feature: "maxOutputTokens"),
            .init(type: "unsupported", feature: "reasoning"), .init(type: "unsupported", feature: "providerOptions.heygen.temperature")])
        #expect(Set(try await heyGenTestRequestBody(transport).objectValue!.keys) == ["model", "state", "questions"])
    }
}
