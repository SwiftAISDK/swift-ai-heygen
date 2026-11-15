import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIHeyGen

// Original illustrative fixture in heygen-decision-model.test.ts (3.0.25).
let heyGenDecisionFixture: JSONValue = ["data": [
    "id": "decision-0123456789abcdef", "request_id": "0123456789abcdef0123456789abcdef", "model": "heygen-decision-1",
    "answers": [
        "blocked": ["type": "noul", "noul": 0.96],
        "team": ["type": "choice", "choice": "video", "probabilities": ["video": 0.8, "account": 0.15, "billing": 0.05], "confidence": 0.7],
        "impact": ["type": "score", "score": 1.75, "probabilities": ["0": 0.05, "1": 0.15, "2": 0.8],
                   "legend": ["0": "Cosmetic", "1": "Slower", "2": "Blocked"], "confidence": 0.625]
    ], "usage": ["input_tokens": 1200, "output_tokens": 0]
]]

let heyGenDecisionQuestions: [String: AIDecisionQuestion] = [
    "blocked": .boolean(instructions: "Is the customer unable to work?"),
    "team": .choice(instructions: "Which team should handle this request?", criteria: ["video": "Rendering", "account": "Access", "billing": "Payments"]),
    "impact": .score(instructions: "How much does this affect the customer?", criteria: ["Cosmetic", "Slower", "Blocked"])
]

func heyGenDecisionOptions() -> AIDecisionModelV4CallOptions {
    .init(state: [.text("Video export fails for everyone.")], questions: heyGenDecisionQuestions)
}

func heyGenDecisionSetup(body: JSONValue = heyGenDecisionFixture, status: Int = 200) throws
    -> (model: any AIDecisionModelV4, transport: RecordingTransport, provider: HeyGenProvider) {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: status,
        headers: ["content-type": "application/json", "x-trace": "trace-1"], body: try JSONEncoder().encode(body)))
    let provider = try createHeyGen(configuration: .init(apiKey: "test-key", baseURL: "https://example.com/",
        headers: ["x-provider": "custom", "shared": "provider"], transport: transport))
    return (try provider.decisionModel("heygen-decision-1"), transport, provider)
}

func heyGenDecisionReplacingData(_ field: String, with value: JSONValue) -> JSONValue {
    var data = heyGenDecisionFixture["data"]!.objectValue!
    data[field] = value
    return ["data": .object(data)]
}

func heyGenDecisionReplacingAnswer(_ id: String, with value: JSONValue) -> JSONValue {
    var answers = heyGenDecisionFixture["data"]!["answers"]!.objectValue!
    answers[id] = value
    return heyGenDecisionReplacingData("answers", with: .object(answers))
}
