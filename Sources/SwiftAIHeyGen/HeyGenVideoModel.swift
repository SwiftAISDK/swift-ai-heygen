import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// HeyGen video generation with resumable V4 start/status operations.
/// Status checks return the refreshed signed MP4 URL without downloading it.
public final class HeyGenVideoModel: AsyncVideoModel, RawVideoGenerationInputModel, Sendable {
    public let providerID = "heygen.video"
    public let modelID: String
    public let supportsUnaryVideoGeneration = false
    public let maxVideosPerCall = 1
    private let config: HeyGenModelConfiguration

    public init(modelID: String, config: HeyGenModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func startVideoGeneration(_ operationRequest: VideoGenerationOperationStartRequest) async throws -> VideoGenerationOperationStartResult {
        let request = operationRequest.request
        try Task.checkCancellation()
        try request.abortSignal?.throwIfAborted()
        let timestamp = Date()
        let prepared = try heyGenVideoPreparedCall(request, modelID: modelID)
        let call = try config.request(
            path: "/v3/models/videos", modelID: modelID, body: prepared.body,
            headers: normalizeHeaders(request.headers), abortSignal: request.abortSignal
        )
        var response = try await config.transport.send(call)
        response.url = response.url ?? call.url
        try Task.checkCancellation()
        try request.abortSignal?.throwIfAborted()
        let raw = try heyGenResponseJSON(response, providerID: providerID, requestBody: prepared.body)
        guard let id = raw["data"]?["video_id"]?.stringValue, !id.isEmpty else {
            throw heyGenMalformedResponse(response, providerID: providerID, field: "data.video_id", requestBody: prepared.body)
        }
        var operation = prepared.operationValues
        operation["videoId"] = .string(id)
        return VideoGenerationOperationStartResult(
            operation: .object(operation), warnings: prepared.warnings,
            providerMetadata: ["heygen": .object(operation)],
            responseMetadata: AIResponseMetadata(timestamp: timestamp, modelID: modelID, headers: response.headers)
        )
    }

    public func videoGenerationStatus(_ request: VideoGenerationOperationStatusRequest) async throws -> VideoGenerationOperationStatusResult {
        try Task.checkCancellation()
        try request.abortSignal?.throwIfAborted()
        let operation = try heyGenVideoOperation(request.operation)
        let timestamp = Date()
        let id = operation["videoId"]!.stringValue!
        let url = try config.url(modelID, "/v3/models/videos/\(heyGenVideoPathComponent(id))")
        var response = try await downloadURL(
            url.absoluteString, transport: config.transport,
            headers: config.headers.mergingHeaders(normalizeHeaders(request.headers)), abortSignal: request.abortSignal,
            trustedOrigin: config.baseURL, credentialedOrigin: config.baseURL
        )
        response.url = response.url ?? url
        try Task.checkCancellation()
        try request.abortSignal?.throwIfAborted()
        let raw = try heyGenResponseJSON(response, providerID: providerID)
        let data = try heyGenStatusData(raw, response: response, providerID: providerID)
        let status = data["status"]!.stringValue!
        let responseMetadata = AIResponseMetadata(timestamp: timestamp, modelID: modelID, headers: response.headers, body: raw)
        var metadata = operation
        for (wire, key) in [("duration", "duration"), ("width", "width"), ("height", "height"), ("aspect_ratio", "aspectRatio"), ("seed", "seed"), ("failure_code", "failureCode")] {
            if let value = data[wire], value != .null { metadata[key] = value }
        }
        if let value = data["timings"]?["inference"], value != .null {
            metadata["timings"] = ["inference": value]
        }
        if ["pending", "processing"].contains(status) {
            return .pending(providerMetadata: ["heygen": .object(metadata)], responseMetadata: responseMetadata)
        }
        if ["failed", "cancelled"].contains(status) {
            let message = data["failure_message"]?.stringValue ?? "HeyGen video generation \(status)"
            let code = data["failure_code"]?.stringValue.map { " (\($0))" } ?? ""
            return .failed(message: message + code, providerMetadata: ["heygen": .object(metadata)], responseMetadata: responseMetadata)
        }
        guard status == "completed", let url = data["video_url"]?.stringValue, !url.isEmpty else {
            throw AIError.invalidResponse(provider: providerID, message: "HeyGen returned an unexpected video status or a completed video without a URL.")
        }
        return .completed(VideoGenerationResult(
            urls: [url], operationID: id, mediaType: "video/mp4", rawValue: raw,
            providerMetadata: ["heygen": ["videos": [.object(metadata)]]], responseMetadata: responseMetadata
        ))
    }
}

private func heyGenVideoOperation(_ raw: JSONValue) throws -> [String: JSONValue] {
    guard raw.objectValue != nil, let id = raw["videoId"]?.stringValue, !id.isEmpty,
          let mode = raw["mode"]?.stringValue, HeyGenVideoModelOptions.Mode(rawValue: mode) != nil,
          let resolution = raw["resolution"]?.stringValue, HeyGenVideoModelOptions.Resolution(rawValue: resolution) != nil else {
        throw heyGenInvalidArgument("operation", "HeyGen operation must contain a nonempty videoId, a valid mode, and a valid resolution.")
    }
    return ["videoId": .string(id), "mode": .string(mode), "resolution": .string(resolution)]
}

private func heyGenVideoPathComponent(_ value: String) -> String {
    // Keep an operation ID inside one path component, including dot-only IDs.
    if value == "." || value == ".." { return value.replacingOccurrences(of: ".", with: "%2E") }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func heyGenResponseJSON(_ response: AIHTTPResponse, providerID: String, requestBody: JSONValue? = nil) throws -> JSONValue {
    guard (200..<300).contains(response.statusCode) else {
        var error = heyGenAPICallError(response, providerID: providerID, requestBody: requestBody)
        if let raw = try? response.jsonValue(), let value = raw["error"],
           let message = value["message"]?.stringValue,
           ["code", "param"].allSatisfy({ value[$0] == nil || value[$0] == .null || value[$0]?.stringValue != nil }) {
            error.message = message
                + (value["code"]?.stringValue.map { " (\($0))" } ?? "")
                + (value["param"]?.stringValue.map { " [\($0)]" } ?? "")
        }
        throw AIError.apiCall(error)
    }
    guard let raw = try? response.jsonValue(), raw.objectValue != nil, raw["data"]?.objectValue != nil else {
        throw heyGenMalformedResponse(response, providerID: providerID, field: "data", requestBody: requestBody)
    }
    return raw
}

private func heyGenStatusData(_ raw: JSONValue, response: AIHTTPResponse, providerID: String) throws -> JSONValue {
    let data = raw["data"]!
    guard data["status"]?.stringValue != nil else { throw heyGenMalformedResponse(response, providerID: providerID, field: "data.status") }
    for key in ["video_url", "aspect_ratio", "failure_code", "failure_message"] {
        if let value = data[key], value != .null, value.stringValue == nil {
            throw heyGenMalformedResponse(response, providerID: providerID, field: "data.\(key)")
        }
    }
    for key in ["duration", "width", "height", "seed"] {
        if let value = data[key], value != .null, value.doubleValue?.isFinite != true {
            throw heyGenMalformedResponse(response, providerID: providerID, field: "data.\(key)")
        }
    }
    if let timings = data["timings"], timings != .null {
        guard timings.objectValue != nil else { throw heyGenMalformedResponse(response, providerID: providerID, field: "data.timings") }
        if let inference = timings["inference"], inference != .null, inference.doubleValue?.isFinite != true {
            throw heyGenMalformedResponse(response, providerID: providerID, field: "data.timings.inference")
        }
    }
    return data
}

private func heyGenAPICallError(_ response: AIHTTPResponse, providerID: String, requestBody: JSONValue? = nil) -> AIAPICallError {
    AIAPICallError(provider: providerID, url: response.url?.absoluteString,
        requestBody: requestBody, statusCode: response.statusCode, responseHeaders: response.headers,
        responseBody: String(data: response.body, encoding: .utf8) ?? "")
}

private func heyGenMalformedResponse(_ response: AIHTTPResponse, providerID: String, field: String, requestBody: JSONValue? = nil) -> AIError {
    var error = heyGenAPICallError(response, providerID: providerID, requestBody: requestBody)
    error.isRetryable = false
    error.message = "Invalid HeyGen response field \(field)."
    return .apiCall(error)
}