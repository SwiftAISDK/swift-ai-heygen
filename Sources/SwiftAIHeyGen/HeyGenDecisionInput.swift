import Foundation
import SwiftAIProvider
import SwiftAIProviderUtilities

func heyGenDecisionQuestions(_ questions: [String: AIDecisionQuestion], modelID: String) throws -> JSONValue {
    let limits = heyGenDecisionModelLimits
    guard (1...limits.maxQuestions).contains(questions.count) else {
        throw heyGenInvalidArgument("questions", "HeyGen Decision supports 1 to \(limits.maxQuestions) questions per request.")
    }
    var native: [String: JSONValue] = [:]
    for (id, question) in questions.sorted(by: { $0.key < $1.key }) {
        guard !id.isEmpty, id.trimmingCharacters(in: .whitespacesAndNewlines) == id,
              !id.contains(":"), !id.contains("\r"), !id.contains("\n") else {
            throw heyGenInvalidArgument("questions", "HeyGen Decision question names must be nonempty, contain no colon or newline, and have no leading or trailing whitespace.")
        }
        let instructions: JSONValue? = question.instructions == .null ? nil : question.instructions
        switch question {
        case let .boolean(_, criteria):
            native[id] = .object(["type": "noul", "instructions": instructions, "criteria": criteria.map(JSONValue.object)])
        case let .choice(_, criteria):
            guard (1...limits.maxChoiceOptions).contains(criteria.count) else {
                throw heyGenInvalidArgument("questions.\(id).criteria", "HeyGen Choice questions support 1 to \(limits.maxChoiceOptions) options.")
            }
            native[id] = .object(["type": "choice", "instructions": instructions, "criteria": .object(criteria)])
        case let .score(_, criteria):
            guard (1...limits.maxScoreLevels).contains(criteria.count), !criteria.contains(.null) else {
                throw heyGenInvalidArgument("questions.\(id).criteria", "HeyGen Score questions require 1 to \(limits.maxScoreLevels) non-null levels.")
            }
            native[id] = .object(["type": "score", "instructions": instructions, "criteria": .array(criteria)])
        case .box:
            throw AIDecisionUnsupportedQuestionTypeError(questionID: id, questionType: .box, providerID: "heygen.decision", modelID: modelID)
        }
    }
    return .object(native)
}

func heyGenDecisionInput(_ parts: [AIDecisionStatePart]) throws -> (state: JSONValue, assets: JSONValue?) {
    var values: [JSONValue] = []
    var images: [String: JSONValue] = [:], videos: [String: JSONValue] = [:]
    for part in parts {
        switch part {
        case let .text(text): values.append(.string(text))
        case let .json(value): values.append(value)
        case let .file(mediaType, data, _, _):
            let kind = topLevelMediaType(mediaType)
            guard kind == "image" || kind == "video" else {
                throw AIDecisionUnsupportedFunctionalityError(functionality: "HeyGen decision file media type: \(mediaType)")
            }
            let asset = try heyGenDecisionAsset(data, mediaType: mediaType, kind: kind)
            if kind == "image" { images["image-\(images.count + 1)"] = asset }
            else { videos["video-\(videos.count + 1)"] = asset }
        }
    }
    let limits = heyGenDecisionModelLimits
    guard images.count <= limits.maxImages, videos.count <= limits.maxVideos else {
        throw heyGenInvalidArgument("state", "HeyGen Decision supports at most \(limits.maxImages) images and \(limits.maxVideos) video per request.")
    }
    let state: JSONValue
    if values.count == 1 {
        switch values[0] { case .string, .object, .array: state = values[0]; default: state = .array(values) }
    } else { state = .array(values) }
    let assets: JSONValue? = images.isEmpty && videos.isEmpty ? nil : .object([
        "images": images.isEmpty ? nil : .object(images), "videos": videos.isEmpty ? nil : .object(videos)
    ])
    return (state, assets)
}

private func heyGenDecisionAsset(_ data: AIDecisionFileData, mediaType: String, kind: String) throws -> JSONValue {
    switch data {
    case let .url(url):
        guard url.scheme == "https" else { throw heyGenInvalidArgument("state", "HeyGen decision media URLs must use HTTPS.") }
        return ["type": "url", "url": .string(url.absoluteString)]
    case let .reference(reference): return ["type": "asset_id", "asset_id": .string(reference)]
    case .data, .base64:
        let detected: String?
        let base64: String
        switch data {
        case let .data(bytes): base64 = bytes.base64EncodedString(); detected = detectMediaType(data: bytes, topLevelType: kind)
        case let .base64(value): base64 = value; detected = detectMediaType(base64: value, topLevelType: kind)
        default: preconditionFailure("Handled by outer data branch")
        }
        guard let resolvedType = isFullMediaType(mediaType) ? mediaType : detected else {
            throw heyGenInvalidArgument("state", "Could not detect the \(kind) media type. Specify a full mediaType such as \(kind == "image" ? "image/png" : "video/mp4").")
        }
        return ["type": "base64", "media_type": .string(resolvedType), "data": .string(base64)]
    }
}
