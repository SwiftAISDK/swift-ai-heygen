import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

public struct HeyGenProviderSettings: Sendable {
    public var apiKey: String?
    /// Supplies a fresh API key immediately before each authenticated request.
    public var apiKeyProvider: (@Sendable () async throws -> String)?
    public var baseURL: String?
    public var headers: [String: String]
    public var queryParams: [String: String]
    public var environment: [String: String]?
    public var transport: any AITransport

    public init(apiKey: String? = nil, apiKeyProvider: (@Sendable () async throws -> String)? = nil, baseURL: String? = nil, headers: [String: String] = [:],
                queryParams: [String: String] = [:], environment: [String: String]? = nil, transport: any AITransport = URLSessionTransport.shared) {
        self.apiKey = apiKey; self.apiKeyProvider = apiKeyProvider; self.baseURL = baseURL; self.headers = headers
        self.queryParams = queryParams; self.environment = environment; self.transport = transport
    }
}

public let heyGenProviderVersion = "3.0.25"

public final class HeyGenProvider: AIProvider, AIDecisionProvider, Sendable {
    public let providerID = "heygen"
    public let specificationVersion = "v4"
    public let supportedCapabilities: Set<ModelCapability> = [.video, .decision]
    private let config: HeyGenModelConfiguration

    public init(configuration: HeyGenProviderSettings = .init()) throws {
        // Retain the released throwing initializer selector while resolving auth
        // at request time for both video and Decision, as in upstream 3.0.25.
        let credential = AIAsyncCredential {
            if let supplier = configuration.apiKeyProvider { return try await supplier() }
            if let key = configuration.apiKey ?? (configuration.environment ?? ProcessInfo.processInfo.environment)["HEYGEN_API_KEY"] {
                return key
            }
            throw AIError.missingAPIKey(provider: "heygen", environmentVariables: ["HEYGEN_API_KEY"])
        }
        var headers = normalizeHeaders(configuration.headers)
        headers["x-api-key"] = headers["x-api-key"] ?? credential.placeholder
        headers = withUserAgentSuffix(headers, "ai-sdk-heygen/\(heyGenProviderVersion)")
        let baseURL = withoutTrailingSlash(configuration.baseURL ?? "https://api.heygen.com")
        let http = AIProviderHTTPClient(providerID: "heygen", headers: headers,
            transport: credential.resolvingTransport(configuration.transport),
            url: { _, path in try providerURL("\(baseURL)\(path)", queryParams: configuration.queryParams) })
        config = HeyGenModelConfiguration(http: http, baseURL: baseURL)
    }

    public func languageModel(_ modelID: String) throws -> any LanguageModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .language, modelID: modelID)
    }

    public func embeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .embedding, modelID: modelID)
    }

    public func imageModel(_ modelID: String) throws -> any ImageModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .image, modelID: modelID)
    }

    public func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .transcription, modelID: modelID)
    }

    public func speechModel(_ modelID: String) throws -> any SpeechModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .speech, modelID: modelID)
    }

    public func videoModel(_ modelID: String) throws -> any VideoModel {
        HeyGenVideoModel(modelID: modelID, config: config)
    }

    public func decisionModel(_ modelID: String) throws -> any AIDecisionModelV4 {
        DecisionHeyGenModel(modelID: modelID, config: config)
    }

    public func decision(_ modelID: String) throws -> any AIDecisionModelV4 { try decisionModel(modelID) }

    public func rerankingModel(_ modelID: String) throws -> any RerankingModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .reranking, modelID: modelID)
    }

    public func chatModel(_ modelID: String) throws -> any LanguageModel { try languageModel(modelID) }
}

public func createHeyGen(configuration: HeyGenProviderSettings = .init()) throws -> HeyGenProvider {
    try HeyGenProvider(configuration: configuration)
}

/// Default HeyGen provider; no credential is needed until a request is sent.
public let heygen: HeyGenProvider = try! createHeyGen()

public extension AIProviders {
    static func heyGen(configuration: HeyGenProviderSettings) throws -> HeyGenProvider {
        try HeyGenProvider(configuration: configuration)
    }
}

public struct HeyGenModelConfiguration: AIProviderHTTPConfiguration {
    public var http: AIProviderHTTPClient
    public var baseURL: String
    public init(http: AIProviderHTTPClient, baseURL: String) {
        self.http = http; self.baseURL = withoutTrailingSlash(baseURL)
    }
}
