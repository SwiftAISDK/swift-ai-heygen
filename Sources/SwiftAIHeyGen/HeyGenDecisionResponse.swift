import Foundation
import SwiftAIProvider
import SwiftAITransport

struct HeyGenParsedDecision {
    var answers: [String: AIDecisionAnswer]
    var usage: AIDecisionModelUsage?
    var metadata: JSONValue
    var id: String?
    var modelID: String?
}

func parseHeyGenDecisionResponse(_ raw: JSONValue, response: AIHTTPResponse, requestBody: JSONValue,
                                questionIDs: Set<String>) throws -> HeyGenParsedDecision {
    func invalid(_ field: String) -> AIError {
        heyGenMalformedResponse(response, providerID: "heygen.decision", field: field, requestBody: requestBody)
    }
    guard let data = raw["data"]?.objectValue, let rawAnswers = data["answers"]?.objectValue else { throw invalid("data.answers") }
    for field in ["id", "request_id", "model"] {
        if let value = data[field], value != .null, value.stringValue == nil { throw invalid("data.\(field)") }
    }
    var answers: [String: AIDecisionAnswer] = [:]
    var confidence: [String: JSONValue] = [:], legends: [String: JSONValue] = [:], warnings: [String: JSONValue] = [:]
    for (id, value) in rawAnswers {
        guard let answer = value.objectValue, let type = answer["type"]?.stringValue else { throw invalid("data.answers.\(id)") }
        func probability(_ value: JSONValue?, field: String) throws -> Double {
            guard let number = value?.doubleValue, number.isFinite, (0...1).contains(number) else { throw invalid(field) }
            return number
        }
        func probabilities() throws -> [String: Double] {
            guard let values = answer["probabilities"]?.objectValue else { throw invalid("data.answers.\(id).probabilities") }
            return try values.mapValues { try probability($0, field: "data.answers.\(id).probabilities") }
        }
        switch type {
        case "noul": answers[id] = .boolean(probability: try probability(answer["noul"], field: "data.answers.\(id).noul"))
        case "choice":
            guard let choice = answer["choice"]?.stringValue else { throw invalid("data.answers.\(id).choice") }
            answers[id] = .choice(choice: choice, probabilities: try probabilities())
        case "score":
            guard let score = answer["score"]?.doubleValue, score.isFinite else { throw invalid("data.answers.\(id).score") }
            answers[id] = .score(score: score, probabilities: try probabilities())
            if let legend = answer["legend"], legend != .null {
                guard legend.objectValue != nil else { throw invalid("data.answers.\(id).legend") }
                legends[id] = legend
            }
        default: throw invalid("data.answers.\(id).type")
        }
        if type != "noul", let value = answer["confidence"], value != .null {
            confidence[id] = .number(try probability(value, field: "data.answers.\(id).confidence"))
        }
        if let warning = answer["warning"], warning != .null {
            guard warning.stringValue != nil else { throw invalid("data.answers.\(id).warning") }
            warnings[id] = warning
        }
    }
    var usage: AIDecisionModelUsage?
    if let value = data["usage"], value != .null {
        guard let object = value.objectValue else { throw invalid("data.usage") }
        for field in ["input_tokens", "output_tokens"] {
            if let value = object[field], value != .null, value.doubleValue?.isFinite != true { throw invalid("data.usage.\(field)") }
        }
        // Swift token counters are integral. Preserve non-integral wire values
        // in raw response metadata and omit their unrepresentable counters.
        func tokenCount(_ value: JSONValue?) -> Int? { value?.doubleValue.flatMap { Int(exactly: $0) } }
        usage = .init(inputTokens: tokenCount(object["input_tokens"]), outputTokens: tokenCount(object["output_tokens"]))
    }
    guard Set(answers.keys) == questionIDs else {
        throw AIError.invalidResponse(provider: "heygen.decision", message: "HeyGen Decision must return exactly one answer for every question.")
    }
    return .init(answers: answers, usage: usage, metadata: .object([
        "requestId": data["request_id"] == .null ? nil : data["request_id"],
        "confidence": .object(confidence), "legend": .object(legends), "answerWarnings": .object(warnings)
    ]), id: data["id"]?.stringValue, modelID: data["model"]?.stringValue)
}
