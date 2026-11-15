import Foundation
import SwiftAIProvider

public typealias HeyGenDecisionModelID = String
public typealias Experimental_HeyGenDecisionModelId = HeyGenDecisionModelID

/// HeyGen Decision has no provider-specific options.
public struct HeyGenDecisionModelOptions: Equatable, Sendable {
    public init() {}
    public var providerOptions: [String: JSONValue] { ["heygen": .object([:])] }
}

public struct HeyGenDecisionModelLimits: Equatable, Sendable {
    public let supportedQuestionTypes: [AIDecisionQuestionType] = [.choice, .score, .boolean]
    public let maxQuestions = 400
    public let maxChoiceOptions = 255
    public let maxScoreLevels = 10
    public let maxImages = 4
    public let maxVideos = 1
    public init() {}
}

public let heyGenDecisionModelLimits = HeyGenDecisionModelLimits()
public let heyGenDecisionModelIDs = ["heygen-decision-1", "heygen-decision-1-turbo"]

public func getHeyGenDecisionModelEntry(_ modelID: String) -> AIModelEntry<JSONValue> {
    .init(capabilities: .init(decision: .init(
        questionTypes: .init(boolean: .supported, choice: .supported, score: .supported, box: .unsupported),
        inputs: .init(image: .supported), reasoning: .unsupported, maxOutputTokens: .unsupported)))
}
