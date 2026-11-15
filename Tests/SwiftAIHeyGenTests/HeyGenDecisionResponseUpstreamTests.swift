import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
import SwiftAIHeyGen

@Suite("HeyGen Decision matching-release responses")
struct HeyGenDecisionResponseUpstreamTests {
    @Test func mapsAnswersAndPreservesConfidenceLegendsWarningsUsageAndMetadata() async throws {
        let body = heyGenDecisionReplacingAnswer("blocked", with: ["type": "noul", "noul": 0.96, "warning": "Low evidence"])
        let result = try await heyGenDecisionSetup(body: body).model.doDecide(heyGenDecisionOptions())
        #expect(result.answers == [
            "blocked": .boolean(probability: 0.96),
            "team": .choice(choice: "video", probabilities: ["video": 0.8, "account": 0.15, "billing": 0.05]),
            "impact": .score(score: 1.75, probabilities: ["0": 0.05, "1": 0.15, "2": 0.8])
        ])
        #expect(result.rounding == nil)
        #expect(result.usage == .init(inputTokens: 1200, outputTokens: 0))
        #expect(result.warnings.isEmpty)
        #expect(result.providerMetadata == ["heygen": [
            "requestId": "0123456789abcdef0123456789abcdef", "confidence": ["team": 0.7, "impact": 0.625],
            "legend": ["impact": ["0": "Cosmetic", "1": "Slower", "2": "Blocked"]], "answerWarnings": ["blocked": "Low evidence"]
        ]])
        #expect(result.response?.id == "decision-0123456789abcdef")
        #expect(result.response?.modelID == "heygen-decision-1")
        #expect(result.response?.headers["x-trace"] == "trace-1")
        #expect(result.response?.body == body)
    }

    @Test func toleratesAbsentAncillaryResponseFields() async throws {
        let body: JSONValue = ["data": ["answers": heyGenDecisionFixture["data"]!["answers"]!]]
        let result = try await heyGenDecisionSetup(body: body).model.doDecide(heyGenDecisionOptions())
        #expect(result.usage == nil)
        #expect(result.response?.id == nil)
        #expect(result.response?.modelID == "heygen-decision-1")
        #expect(result.providerMetadata["heygen"]?["requestId"] == nil)
    }

    static let incorrectAnswerSets: [JSONValue] = [
        .object([String: JSONValue]()),
        heyGenDecisionReplacingAnswer("extra", with: heyGenDecisionFixture["data"]!["answers"]!["blocked"]!)["data"]!["answers"]!,
        ["team": heyGenDecisionFixture["data"]!["answers"]!["team"]!, "impact": heyGenDecisionFixture["data"]!["answers"]!["impact"]!]
    ]

    @Test(arguments: incorrectAnswerSets)
    func rejectsMissingAndUnexpectedAnswers(_ answers: JSONValue) async throws {
        let model = try heyGenDecisionSetup(body: ["data": ["answers": answers]]).model
        await #expect(throws: AIError.invalidResponse(provider: "heygen.decision", message: "HeyGen Decision must return exactly one answer for every question.")) {
            try await model.doDecide(heyGenDecisionOptions())
        }
    }

    static let malformedAnswers: [JSONValue] = [
        heyGenDecisionReplacingAnswer("blocked", with: ["type": "noul", "noul": 1.01]),
        heyGenDecisionReplacingAnswer("team", with: ["type": "choice", "choice": "video"]),
        heyGenDecisionReplacingAnswer("blocked", with: ["type": "refusal"])
    ]

    @Test(arguments: malformedAnswers)
    func rejectsMalformedNativeResponsesAsAPICallErrors(_ body: JSONValue) async throws {
        let model = try heyGenDecisionSetup(body: body).model
        do { _ = try await model.doDecide(heyGenDecisionOptions()); Issue.record("Expected API call error") }
        catch let AIError.apiCall(error) { #expect(error.statusCode == 200); #expect(!error.isRetryable) }
    }

    @Test func preservesHeyGenErrorCodesAndParameters() async throws {
        let body: JSONValue = ["error": ["code": "invalid_parameter", "message": "Invalid question.", "param": "questions.team.criteria"]]
        let model = try heyGenDecisionSetup(body: body, status: 400).model
        do { _ = try await model.doDecide(heyGenDecisionOptions()); Issue.record("Expected API call error") }
        catch let AIError.apiCall(error) {
            #expect(error.message == "Invalid question. (invalid_parameter) [questions.team.criteria]")
            #expect(error.statusCode == 400)
            #expect(error.url == "https://example.com/v3/models/decisions")
            #expect(try JSONDecoder().decode(JSONValue.self, from: Data(error.responseBody.utf8)) == body)
        }
    }

    @Test func loadsEnvironmentAuthenticationLazilyAndUsesDefaultEndpoint() async throws {
        let previous = ProcessInfo.processInfo.environment["HEYGEN_API_KEY"]
        unsetenv("HEYGEN_API_KEY")
        defer {
            if let previous { setenv("HEYGEN_API_KEY", previous, 1) }
            else { unsetenv("HEYGEN_API_KEY") }
        }
        let transport = RecordingTransport(response: jsonResponse(String(data: try JSONEncoder().encode(heyGenDecisionFixture), encoding: .utf8)!))
        let provider = try createHeyGen(configuration: .init(transport: transport))
        let model = try provider.decisionModel("heygen-decision-1-turbo")
        setenv("HEYGEN_API_KEY", "environment-key", 1)
        _ = try await model.doDecide(heyGenDecisionOptions())
        let call = try #require(await transport.requests().first)
        #expect(call.url.absoluteString == "https://api.heygen.com/v3/models/decisions")
        #expect(call.headers["x-api-key"] == "environment-key")
        #expect(try await heyGenTestRequestBody(transport)["model"] == "heygen-decision-1-turbo")
        let envTransport = RecordingTransport(response: jsonResponse(String(data: try JSONEncoder().encode(heyGenDecisionFixture), encoding: .utf8)!))
        let fromEnvironment = try createHeyGen(configuration: .init(environment: ["HEYGEN_API_KEY": "environment-key"], transport: envTransport))
        _ = try await fromEnvironment.decisionModel("heygen-decision-1-turbo").doDecide(heyGenDecisionOptions())
        #expect(await envTransport.requests().first?.headers["x-api-key"] == "environment-key")
    }
}
