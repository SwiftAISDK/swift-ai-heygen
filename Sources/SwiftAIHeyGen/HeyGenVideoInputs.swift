import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


struct HeyGenVideoPreparedCall {
    var body: JSONValue
    var operationValues: [String: JSONValue]
    var warnings: [AIWarning]
}

func heyGenVideoPreparedCall(_ request: VideoGenerationRequest, modelID: String) throws -> HeyGenVideoPreparedCall {
    let options = try heyGenVideoOptions(request)
    guard !request.prompt.isEmpty, request.prompt.utf16.count <= 32_000 else {
        throw heyGenInvalidArgument("prompt", "HeyGen requires a prompt between 1 and 32,000 characters.")
    }
    if let duration = request.durationSeconds, !duration.isFinite || duration.rounded() != duration || duration < 5 || duration > 15 {
        throw heyGenInvalidArgument("duration", "HeyGen duration must be an integer between 5 and 15 seconds.")
    }
    if let seed = request.seed, seed < 0 || seed > Int(UInt32.max) {
        throw heyGenInvalidArgument("seed", "HeyGen seed must be an unsigned 32-bit integer.")
    }
    var warnings: [AIWarning] = []
    if (request.count ?? 1) > 1 { warnings.append(heyGenWarning("n", "HeyGen generates one video per call.")) }
    if let fps = request.fps, fps != 24 { warnings.append(heyGenWarning("fps", "HeyGen generates video at 24 fps.")) }
    if request.generateAudio == false { warnings.append(heyGenWarning("generateAudio", "HeyGen always generates audio alongside the video.")) }

    guard request.frameImages.count <= 1, request.frameImages.allSatisfy({ $0.frameType == .firstFrame }) else {
        throw heyGenInvalidArgument("frameImages", "HeyGen supports a single first frame, not last-frame conditioning.")
    }
    if !request.frameImages.isEmpty, request.image != nil {
        throw heyGenInvalidArgument("image", "Supply either image or a first frame, not both.")
    }
    let firstFrame = request.frameImages.first?.image ?? request.image
    if firstFrame != nil, options["image"] != nil {
        throw heyGenInvalidArgument("image", "Supply either a standard image or providerOptions.heygen.image, not both.")
    }
    let image = try firstFrame.map { try heyGenFileAsset($0, kind: "image") } ?? options["image"]
    var images: [JSONValue] = [], videos: [JSONValue] = [], audio: [JSONValue] = []
    for reference in request.inputReferences {
        if reference.mediaType?.hasPrefix("video/") == true {
            videos.append(try heyGenFileAsset(reference, kind: "video"))
        } else if reference.mediaType?.hasPrefix("audio/") == true {
            audio.append(try heyGenFileAsset(reference, kind: "audio"))
        } else if reference.mediaType?.hasPrefix("image/") == true {
            images.append(try heyGenFileAsset(reference, kind: "image"))
        } else {
            throw heyGenInvalidArgument("inputReferences", "HeyGen references require an image, video, or audio mediaType.")
        }
    }
    images += options["referenceImages"]?.arrayValue ?? []
    videos += options["referenceVideos"]?.arrayValue ?? []
    audio += options["referenceAudio"]?.arrayValue ?? []
    let count = images.count + videos.count + audio.count
    guard images.count <= 9, videos.count <= 3, audio.count <= 3, count <= 12 else {
        throw heyGenInvalidArgument("inputReferences", "HeyGen accepts at most 9 images, 3 videos, 3 audio references, and 12 references in total.")
    }
    let mode = options["mode"]?.stringValue ?? (image != nil ? "image_to_video" : count > 0 ? "reference_to_video" : "text_to_video")
    guard (mode == "image_to_video") == (image != nil) else {
        throw heyGenInvalidArgument("image", "A first-frame image is required for image_to_video and cannot be used in other modes.")
    }
    guard !(mode != "reference_to_video" && count > 0), !(mode == "reference_to_video" && images.isEmpty && videos.isEmpty) else {
        throw heyGenInvalidArgument("inputReferences", "References are only supported in reference_to_video, which requires at least one image or video reference.")
    }

    let frameSize = options["resolution"] == nil ? request.resolution.flatMap { heyGenFrameSizes[$0] } : nil
    if request.resolution != nil, options["resolution"] == nil, frameSize == nil {
        throw heyGenInvalidArgument("resolution", "Unsupported HeyGen frame size. Use a documented frame size or providerOptions.heygen.resolution to select 480p, 768p, 1080p, or 2k.")
    }
    let resolution = options["resolution"]?.stringValue ?? frameSize?.resolution ?? "768p"
    let ratio = request.aspectRatio ?? frameSize?.aspectRatio ?? (mode == "text_to_video" ? "16:9" : "adaptive")
    if mode == "image_to_video" {
        if request.aspectRatio != nil || frameSize != nil {
            warnings.append(heyGenWarning("aspectRatio", "HeyGen image-to-video follows the first frame aspect ratio; only the resolution size class is applied."))
        }
    } else {
        let ratios: Set<String> = ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]
        guard ratios.contains(ratio) || (mode == "reference_to_video" && ratio == "adaptive") else {
            throw heyGenInvalidArgument("aspectRatio", "Unsupported HeyGen aspect ratio for \(mode): \(ratio).")
        }
        if ["1080p", "2k"].contains(resolution), !["16:9", "9:16"].contains(ratio) {
            throw heyGenInvalidArgument("aspectRatio", "HeyGen 1080p and 2k require an explicit 16:9 or 9:16 aspect ratio for text-to-video and reference-to-video.")
        }
    }
    var body: [String: JSONValue] = [
        "model": .string(modelID), "mode": .string(mode), "prompt": .string(request.prompt),
        "duration": .number(request.durationSeconds ?? 5), "resolution": .string(resolution)
    ]
    if mode != "image_to_video" { body["aspect_ratio"] = .string(ratio) }
    body["seed"] = request.seed.map { .number(Double($0)) }
    body["prompt_enhancement"] = options["promptEnhancement"]
    if let image { body["image"] = try heyGenAssetBody(image, kind: "image") }
    for (key, assets, kind) in [("reference_images", images, "image"), ("reference_videos", videos, "video"), ("reference_audio", audio, "audio")] where !assets.isEmpty {
        body[key] = .array(try assets.map { try heyGenAssetBody($0, kind: kind) })
    }
    return HeyGenVideoPreparedCall(body: .object(body), operationValues: ["mode": .string(mode), "resolution": .string(resolution)], warnings: warnings)
}

private func heyGenWarning(_ feature: String, _ message: String) -> AIWarning {
    AIWarning(type: "unsupported", feature: feature, message: message)
}

private let heyGenFrameSizes: [String: (resolution: String, aspectRatio: String)] = [
    "960x416": ("480p", "21:9"), "832x480": ("480p", "16:9"), "640x480": ("480p", "4:3"),
    "480x480": ("480p", "1:1"), "480x640": ("480p", "3:4"), "480x832": ("480p", "9:16"),
    "1536x672": ("768p", "21:9"), "1344x768": ("768p", "16:9"), "1024x768": ("768p", "4:3"),
    "768x768": ("768p", "1:1"), "768x1024": ("768p", "3:4"), "768x1344": ("768p", "9:16"),
    "1890x1080": ("1080p", "16:9"), "1080x1890": ("1080p", "9:16"),
    "2688x1536": ("2k", "16:9"), "1536x2688": ("2k", "9:16")
]