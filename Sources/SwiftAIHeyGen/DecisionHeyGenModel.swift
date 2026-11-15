import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

/// HeyGen's native multimodal `/v3/models/decisions` adapter.
public final class DecisionHeyGenModel: AIDecisionModelV4, Sendable {
    public let specificationVersion = "v4"
    public let providerID = "heygen.decision"
    public let modelID: String
    public let supportedQuestionTypes = heyGenDecisionModelLimits.supportedQuestionTypes
    private let config: HeyGenModelConfiguration

    public init(modelID: String, config: HeyGenModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func doDecide(_ options: AIDecisionModelV4CallOptions) async throws -> AIDecisionModelV4Result {
        let questions = try heyGenDecisionQuestions(options.questions, modelID: modelID)
        let input = try heyGenDecisionInput(options.state)
        try Task.checkCancellation()
        try options.abortSignal?.throwIfAborted()
        let body: JSONValue = .object(["model": .string(modelID), "state": input.state,
                                       "assets": input.assets, "questions": questions])
        let call = try config.request(path: "/v3/models/decisions", modelID: modelID, body: body,
                                      headers: normalizeHeaders(options.headers), abortSignal: options.abortSignal)
        var response = try await config.transport.send(call)
        try Task.checkCancellation()
        try options.abortSignal?.throwIfAborted()
        response.url = response.url ?? call.url
        let raw = try heyGenResponseJSON(response, providerID: providerID, requestBody: body)
        let parsed = try parseHeyGenDecisionResponse(raw, response: response, requestBody: body,
                                                    questionIDs: Set(options.questions.keys))
        var warnings: [AIWarning] = []
        if options.maxOutputTokens != nil { warnings.append(.init(type: "unsupported", feature: "maxOutputTokens")) }
        if options.reasoning != nil { warnings.append(.init(type: "unsupported", feature: "reasoning")) }
        warnings += (options.providerOptions["heygen"]?.objectValue ?? [:]).keys.sorted().map {
            .init(type: "unsupported", feature: "providerOptions.heygen.\($0)")
        }
        return .init(answers: parsed.answers, usage: parsed.usage, warnings: warnings,
                     providerMetadata: ["heygen": parsed.metadata],
                     response: .init(id: parsed.id, modelID: parsed.modelID ?? modelID, headers: response.headers, body: raw))
    }
}
