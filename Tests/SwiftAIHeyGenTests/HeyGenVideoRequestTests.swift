@testable import SwiftAIHeyGen
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

/// Request and input fixtures from heygen-video-model.test.ts.
@Suite struct HeyGenVideoRequestTests {
    @Test func textDefaultsAndSerializableOperation() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated, headers: ["x-request-id": "created"]))
        let before = Date()
        let result = try await heyGenTestStart(transport)
        #expect(try await heyGenTestRequestBody(transport) == [
            "model": "heygen-video-1", "mode": "text_to_video", "prompt": "A paper boat floats down a quiet stream.",
            "duration": 5, "resolution": "768p", "aspect_ratio": "16:9"
        ])
        let call = try #require(await transport.requests().first)
        #expect(call.url.absoluteString == "https://api.heygen.com/v3/models/videos")
        #expect(call.headers["x-api-key"] == "test-key")
        #expect(call.headers["content-type"] == "application/json")
        #expect(result.operation == heyGenOperation)
        #expect(result.providerMetadata == ["heygen": heyGenOperation])
        #expect(result.warnings.isEmpty)
        #expect(result.responseMetadata.timestamp! >= before)
        #expect(result.responseMetadata.timestamp! <= Date())
        #expect(result.responseMetadata.modelID == "heygen-video-1")
        #expect(result.responseMetadata.headers["x-request-id"] == "created")
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result.operation)) == heyGenOperation)
    }

    @Test func typedOptionsAndIdempotencyHeader() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let request = VideoGenerationRequest(prompt: "Portrait", aspectRatio: "9:16", durationSeconds: 15, seed: 0,
            providerOptions: HeyGenVideoModelOptions(resolution: .twoK, promptEnhancement: .disabled).providerOptions,
            headers: ["Idempotency-Key": "generation-1"])
        _ = try await heyGenTestStart(transport, request: request)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["duration"] == 15 && body["seed"] == 0)
        #expect(body["aspect_ratio"] == "9:16" && body["resolution"] == "2k")
        #expect(body["prompt_enhancement"] == "disabled")
        #expect(await transport.requests().first?.headers["idempotency-key"] == "generation-1")
    }

    @Test func imageModeIgnoresAspectRatioWithWarning() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let result = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Animate", aspectRatio: "1:1", image: heyGenImage))
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["mode"] == "image_to_video")
        #expect(body["image"] == ["type": "url", "url": "https://example.com/image.jpg"])
        #expect(body["aspect_ratio"] == nil)
        #expect(result.warnings.map(\.feature) == ["aspectRatio"])
    }

    @Test func firstFrameIsAcceptedThroughBothPublicFacades() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(heyGenCreated), jsonResponse(heyGenCreated), jsonResponse(heyGenCompleted)])
        let model = try heyGenTestModel(transport)
        let request = VideoGenerationRequest(prompt: "Animate", frameImages: [VideoFrameImage(image: heyGenImage, frameType: .firstFrame)],
            providerOptions: HeyGenVideoModelOptions(resolution: .p1080).providerOptions)
        let started = try await AI.startVideo(model: model, request: request, retryPolicy: .none)
        #expect(started.warnings.isEmpty)
        let result = try await AI.generateVideo(model: model, request: request, retryPolicy: .none,
            poll: VideoGenerationPollOptions(intervalMilliseconds: 0, timeoutMilliseconds: 10_000, delay: { _, _ in }))
        #expect(result.urls == ["https://resource2.heygen.ai/video.mp4"])
        for i in [0, 1] {
            let body = try await heyGenTestRequestBody(transport, index: i)
            #expect(body["mode"] == "image_to_video" && body["resolution"] == "1080p")
            #expect(body["aspect_ratio"] == nil)
        }
    }

    @Test func bytesAndExistingBase64AreNotDoubleEncoded() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let request = VideoGenerationRequest(prompt: "Use references", inputReferences: [ImageInputFile(data: Data([1, 2, 3]), mediaType: "image/png")],
            providerOptions: HeyGenVideoModelOptions(referenceImages: [.base64(data: "BAUG", mediaType: "image/jpeg")]).providerOptions)
        _ = try await heyGenTestStart(transport, request: request)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["mode"] == "reference_to_video" && body["aspect_ratio"] == "adaptive")
        #expect(body["reference_images"] == [
            ["type": "base64", "media_type": "image/png", "data": "AQID"],
            ["type": "base64", "media_type": "image/jpeg", "data": "BAUG"]
        ])
    }

    @Test func mixedReferencesPreserveOrderAndAppendProviderAssets() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let request = VideoGenerationRequest(prompt: "Use references", inputReferences: [heyGenVideo, heyGenImage, heyGenAudio],
            providerOptions: HeyGenVideoModelOptions(referenceImages: [.assetID("image-2")], referenceVideos: [.assetID("video-2")],
                referenceAudio: [.base64(data: "AQID", mediaType: "audio/mpeg")]).providerOptions)
        _ = try await heyGenTestStart(transport, request: request)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["reference_images"] == [["type": "url", "url": "https://example.com/image.jpg"], ["type": "asset_id", "asset_id": "image-2"]])
        #expect(body["reference_videos"] == [["type": "url", "url": "https://example.com/video.mp4"], ["type": "asset_id", "asset_id": "video-2"]])
        #expect(body["reference_audio"] == [["type": "url", "url": "https://example.com/audio.mp3"], ["type": "base64", "media_type": "audio/mpeg", "data": "AQID"]])
    }

    @Test func assetFirstFrameAndNativeOptionDefaults() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let request = VideoGenerationRequest(prompt: "Animate",
            providerOptions: HeyGenVideoModelOptions(resolution: .p768, image: .assetID("first-frame")).providerOptions,
            extraBody: ["heygen": ["resolution": "480p", "promptEnhancement": "quality", "unknown": true]])
        _ = try await heyGenTestStart(transport, request: request)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["image"] == ["type": "asset_id", "asset_id": "first-frame"])
        #expect(body["resolution"] == "768p")
        #expect(body["prompt_enhancement"] == "quality")
        #expect(body["unknown"] == nil)
    }

    @Test(arguments: [
        ["960x416", "480p", "21:9"], ["832x480", "480p", "16:9"], ["640x480", "480p", "4:3"],
        ["480x480", "480p", "1:1"], ["480x640", "480p", "3:4"], ["480x832", "480p", "9:16"],
        ["1536x672", "768p", "21:9"], ["1344x768", "768p", "16:9"], ["1024x768", "768p", "4:3"],
        ["768x768", "768p", "1:1"], ["768x1024", "768p", "3:4"], ["768x1344", "768p", "9:16"],
        ["1890x1080", "1080p", "16:9"], ["1080x1890", "1080p", "9:16"], ["2688x1536", "2k", "16:9"], ["1536x2688", "2k", "9:16"]
    ]) func documentedFrameSizes(_ fixture: [String]) async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        _ = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", resolution: fixture[0]))
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["resolution"]?.stringValue == fixture[1])
        #expect(body["aspect_ratio"]?.stringValue == fixture[2])
    }

    @Test func providerResolutionTakesPrecedenceOverUnknownStandardSize() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        _ = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", resolution: "1920x1080", providerOptions: HeyGenVideoModelOptions(resolution: .p480).providerOptions))
        #expect(try await heyGenTestRequestBody(transport)["resolution"] == "480p")
    }

    @Test func unsupportedOptionsWarnAndAreOmitted() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let result = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", fps: 30, generateAudio: false, count: 2))
        #expect(result.warnings.map(\.feature) == ["n", "fps", "generateAudio"])
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["fps"] == nil && body["generate_audio"] == nil && body["n"] == nil)
    }

    @Test func supportedFixedFrameRateAndAudioDoNotWarn() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let result = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: String(repeating: "😀", count: 16_000), fps: 24, generateAudio: true, seed: Int(UInt32.max)))
        #expect(result.warnings.isEmpty)
    }
}
