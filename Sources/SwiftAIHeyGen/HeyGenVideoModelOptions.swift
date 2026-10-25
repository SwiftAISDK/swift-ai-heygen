import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// A URL, existing HeyGen workspace asset, or inline reference.
public enum HeyGenVideoAsset: Sendable, Equatable {
    case url(String)
    case assetID(String)
    case base64(data: String, mediaType: String)

    /// The camelCase provider-option representation, before wire conversion.
    public var jsonValue: JSONValue {
        switch self {
        case let .url(url): return ["type": "url", "url": .string(url)]
        case let .assetID(id): return ["type": "asset_id", "assetId": .string(id)]
        case let .base64(data, mediaType):
            return ["type": "base64", "data": .string(data), "mediaType": .string(mediaType)]
        }
    }
}

/// Published @ai-sdk/heygen 3.0.0 video options. Validation occurs before I/O.
public struct HeyGenVideoModelOptions: Sendable, Equatable {
    public enum Mode: String, Sendable, Codable {
        case textToVideo = "text_to_video"
        case imageToVideo = "image_to_video"
        case referenceToVideo = "reference_to_video"
    }

    public enum Resolution: String, Sendable, Codable {
        case p480 = "480p", p768 = "768p", p1080 = "1080p", twoK = "2k"
    }

    public enum PromptEnhancement: String, Sendable, Codable {
        case turbo, quality, disabled
    }

    public var mode: Mode?
    public var resolution: Resolution?
    public var promptEnhancement: PromptEnhancement?
    public var image: HeyGenVideoAsset?
    public var referenceImages: [HeyGenVideoAsset]?
    public var referenceVideos: [HeyGenVideoAsset]?
    public var referenceAudio: [HeyGenVideoAsset]?

    public init(
        mode: Mode? = nil,
        resolution: Resolution? = nil,
        promptEnhancement: PromptEnhancement? = nil,
        image: HeyGenVideoAsset? = nil,
        referenceImages: [HeyGenVideoAsset]? = nil,
        referenceVideos: [HeyGenVideoAsset]? = nil,
        referenceAudio: [HeyGenVideoAsset]? = nil
    ) {
        self.mode = mode
        self.resolution = resolution
        self.promptEnhancement = promptEnhancement
        self.image = image
        self.referenceImages = referenceImages
        self.referenceVideos = referenceVideos
        self.referenceAudio = referenceAudio
    }

    public var jsonValue: JSONValue {
        var value: [String: JSONValue] = [:]
        value["mode"] = mode.map { .string($0.rawValue) }
        value["resolution"] = resolution.map { .string($0.rawValue) }
        value["promptEnhancement"] = promptEnhancement.map { .string($0.rawValue) }
        value["image"] = image?.jsonValue
        value["referenceImages"] = referenceImages.map { .array($0.map(\.jsonValue)) }
        value["referenceVideos"] = referenceVideos.map { .array($0.map(\.jsonValue)) }
        value["referenceAudio"] = referenceAudio.map { .array($0.map(\.jsonValue)) }
        return .object(value)
    }

    public var providerOptions: [String: JSONValue] { ["heygen": jsonValue] }
}

func heyGenInvalidArgument(_ argument: String, _ message: String) -> AIError {
    .invalidArgument(argument: argument, message: message)
}

func heyGenVideoOptions(_ request: VideoGenerationRequest) throws -> [String: JSONValue] {
    // Native extraBody supplies option defaults; explicit provider options win.
    var options = request.extraBody["heygen"]?.objectValue ?? request.extraBody.filter { $0.key != "heygen" }
    if let raw = request.providerOptions["heygen"], raw != .null {
        guard let values = raw.objectValue else {
            throw heyGenInvalidArgument("providerOptions.heygen", "HeyGen provider options must be an object.")
        }
        options.merge(values) { _, new in new }
    }
    var validated: [String: JSONValue] = [:]
    let allowed: [String: Set<String>] = [
        "mode": ["text_to_video", "image_to_video", "reference_to_video"],
        "resolution": ["480p", "768p", "1080p", "2k"],
        "promptEnhancement": ["turbo", "quality", "disabled"]
    ]
    for (key, choices) in allowed {
        guard let value = options[key] else { continue }
        guard let text = value.stringValue, choices.contains(text) else {
            throw heyGenInvalidArgument("providerOptions.heygen.\(key)", "Invalid HeyGen \(key).")
        }
        validated[key] = value
    }
    if let image = options["image"] {
        validated["image"] = try heyGenParseAsset(image, argument: "providerOptions.heygen.image")
    }
    for (key, limit) in [("referenceImages", 9), ("referenceVideos", 3), ("referenceAudio", 3)] {
        guard let value = options[key] else { continue }
        guard let assets = value.arrayValue, assets.count <= limit else {
            throw heyGenInvalidArgument("providerOptions.heygen.\(key)", "HeyGen \(key) must be an array with at most \(limit) assets.")
        }
        validated[key] = .array(try assets.map { try heyGenParseAsset($0, argument: "providerOptions.heygen.\(key)") })
    }
    return validated
}

private func heyGenParseAsset(_ raw: JSONValue, argument: String) throws -> JSONValue {
    guard raw.objectValue != nil, let type = raw["type"]?.stringValue else {
        throw heyGenInvalidArgument(argument, "HeyGen assets must have a url, asset_id, or base64 type.")
    }
    switch type {
    case "url":
        guard let url = raw["url"]?.stringValue, heyGenIsHTTPSURL(url) else {
            throw heyGenInvalidArgument(argument, "HeyGen input URLs must be absolute HTTPS URLs.")
        }
        return ["type": "url", "url": .string(url)]
    case "asset_id":
        guard let id = raw["assetId"]?.stringValue, !id.isEmpty else {
            throw heyGenInvalidArgument(argument, "HeyGen assetId must be a nonempty string.")
        }
        return ["type": "asset_id", "assetId": .string(id)]
    case "base64":
        guard let mediaType = raw["mediaType"]?.stringValue, !mediaType.isEmpty,
              let data = raw["data"]?.stringValue, !data.isEmpty else {
            throw heyGenInvalidArgument(argument, "HeyGen inline assets require nonempty mediaType and data strings.")
        }
        return ["type": "base64", "mediaType": .string(mediaType), "data": .string(data)]
    default:
        throw heyGenInvalidArgument(argument, "Unknown HeyGen asset type \(type).")
    }
}

func heyGenIsHTTPSURL(_ string: String) -> Bool {
    guard string.hasPrefix("https://"), let url = URLComponents(string: string),
          url.scheme == "https", let host = url.host, !host.isEmpty else { return false }
    return true
}

func heyGenAssetBody(_ asset: JSONValue, kind: String) throws -> JSONValue {
    switch asset["type"]?.stringValue {
    case "url":
        guard let url = asset["url"]?.stringValue, heyGenIsHTTPSURL(url) else {
            throw heyGenInvalidArgument(kind, "HeyGen input URLs must be absolute HTTPS URLs.")
        }
        return ["type": "url", "url": .string(url)]
    case "asset_id":
        return ["type": "asset_id", "asset_id": asset["assetId"] ?? .null]
    case "base64":
        guard let mediaType = asset["mediaType"]?.stringValue, mediaType.hasPrefix("\(kind)/") else {
            throw heyGenInvalidArgument(kind, "Expected a \(kind) mediaType.")
        }
        return ["type": "base64", "media_type": .string(mediaType), "data": asset["data"] ?? .null]
    default:
        throw heyGenInvalidArgument(kind, "Invalid HeyGen asset.")
    }
}

func heyGenFileAsset(_ file: ImageInputFile, kind: String) throws -> JSONValue {
    if let mediaType = file.mediaType, !mediaType.hasPrefix("\(kind)/") {
        throw heyGenInvalidArgument(kind, "Expected a \(kind) mediaType.")
    }
    if let url = file.url { return ["type": "url", "url": .string(url)] }
    guard let data = file.data, let mediaType = file.mediaType else {
        throw heyGenInvalidArgument(kind, "HeyGen file inputs require data and a mediaType.")
    }
    return ["type": "base64", "mediaType": .string(mediaType), "data": .string(data.base64EncodedString())]
}