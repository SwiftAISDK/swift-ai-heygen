@testable import SwiftAIHeyGen
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

enum HeyGenInvalidInput: String, CaseIterable, Sendable {
    case emptyPrompt, longPrompt, unicodePrompt, shortDuration, longDuration, fractionalDuration, nonfiniteDuration
    case negativeSeed, largeSeed, unknownResolution, textAdaptiveRatio, unsupportedRatio, highResolutionSquare, highResolutionAdaptiveReferences
    case audioOnly, untypedReference, insecureURL, videoAsImage, lastFrame, multipleFirstFrames, twoFirstFrameSources, frameAndReferences
    case imageAndReferences, twoImageSources, imageModeWithoutImage, referenceModeWithoutReferences, textModeWithImage, textModeWithReferences
    case tooManyImages, tooManyVideos, tooManyAudio, tooManyCombined, combinedImageLimit, wrongReferenceMediaType

    var request: VideoGenerationRequest {
        var r = VideoGenerationRequest(prompt: "Scene")
        switch self {
        case .emptyPrompt: r.prompt = ""
        case .longPrompt: r.prompt = String(repeating: "x", count: 32_001)
        case .unicodePrompt: r.prompt = String(repeating: "😀", count: 16_001)
        case .shortDuration: r.durationSeconds = 4
        case .longDuration: r.durationSeconds = 16
        case .fractionalDuration: r.durationSeconds = 5.5
        case .nonfiniteDuration: r.durationSeconds = .infinity
        case .negativeSeed: r.seed = -1
        case .largeSeed: r.seed = 4_294_967_296
        case .unknownResolution: r.resolution = "1920x1080"
        case .textAdaptiveRatio: r.aspectRatio = "adaptive"
        case .unsupportedRatio: r.aspectRatio = "2:1"
        case .highResolutionSquare:
            r.aspectRatio = "1:1"; r.providerOptions = HeyGenVideoModelOptions(resolution: .twoK).providerOptions
        case .highResolutionAdaptiveReferences:
            r.inputReferences = [heyGenImage]; r.providerOptions = HeyGenVideoModelOptions(resolution: .p1080).providerOptions
        case .audioOnly: r.inputReferences = [heyGenAudio]
        case .untypedReference: r.inputReferences = [ImageInputFile(url: "https://example.com/image.jpg")]
        case .insecureURL: r.image = ImageInputFile(url: "http://example.com/image.png")
        case .videoAsImage: r.image = heyGenVideo
        case .lastFrame: r.frameImages = [VideoFrameImage(image: heyGenImage, frameType: .lastFrame)]
        case .multipleFirstFrames: r.frameImages = Array(repeating: VideoFrameImage(image: heyGenImage, frameType: .firstFrame), count: 2)
        case .twoFirstFrameSources:
            r.image = heyGenImage; r.frameImages = [VideoFrameImage(image: heyGenImage, frameType: .firstFrame)]
        case .frameAndReferences:
            r.frameImages = [VideoFrameImage(image: heyGenImage, frameType: .firstFrame)]; r.inputReferences = [heyGenVideo]
        case .imageAndReferences: r.image = heyGenImage; r.inputReferences = [heyGenVideo]
        case .twoImageSources:
            r.image = heyGenImage; r.providerOptions = HeyGenVideoModelOptions(image: .assetID("another")).providerOptions
        case .imageModeWithoutImage: r.providerOptions = HeyGenVideoModelOptions(mode: .imageToVideo).providerOptions
        case .referenceModeWithoutReferences: r.providerOptions = HeyGenVideoModelOptions(mode: .referenceToVideo).providerOptions
        case .textModeWithImage:
            r.image = heyGenImage; r.providerOptions = HeyGenVideoModelOptions(mode: .textToVideo).providerOptions
        case .textModeWithReferences:
            r.inputReferences = [heyGenImage]; r.providerOptions = HeyGenVideoModelOptions(mode: .textToVideo).providerOptions
        case .tooManyImages: r.inputReferences = Array(repeating: heyGenImage, count: 10)
        case .tooManyVideos: r.inputReferences = Array(repeating: heyGenVideo, count: 4)
        case .tooManyAudio: r.inputReferences = [heyGenImage] + Array(repeating: heyGenAudio, count: 4)
        case .tooManyCombined: r.inputReferences = Array(repeating: heyGenImage, count: 9) + Array(repeating: heyGenVideo, count: 3) + [heyGenAudio]
        case .combinedImageLimit:
            r.inputReferences = Array(repeating: heyGenImage, count: 9)
            r.providerOptions = HeyGenVideoModelOptions(referenceImages: [.assetID("extra")]).providerOptions
        case .wrongReferenceMediaType:
            r.providerOptions = HeyGenVideoModelOptions(referenceImages: [.base64(data: "AQID", mediaType: "audio/mpeg")]).providerOptions
        }
        return r
    }
}

@Suite struct HeyGenVideoValidationTests {
    @Test(arguments: HeyGenInvalidInput.allCases) func invalidInputsFailBeforeDirectOrFacadeIO(_ fixture: HeyGenInvalidInput) async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        await #expect(throws: AIError.self) { try await heyGenTestStart(transport, request: fixture.request) }
        await #expect(throws: AIError.self) {
            try await AI.startVideo(model: heyGenTestModel(transport), request: fixture.request, retryPolicy: .none)
        }
        #expect(await transport.requests().isEmpty)
    }

    static let invalidOptions: [JSONValue] = [
        "string", ["mode": "unknown"], ["mode": .null], ["resolution": "4k"], ["promptEnhancement": "unknown"],
        ["image": ["type": "asset_id", "assetId": ""]], ["image": ["type": "other"]],
        ["image": ["type": "url", "url": "https://"]], ["image": ["type": "url", "url": "http://example.com/image.png"]],
        ["image": ["type": "base64", "mediaType": "image/png", "data": ""]],
        ["referenceImages": "not an array"], ["referenceVideos": [.null]],
        ["referenceAudio": [["type": "base64", "mediaType": "", "data": "AQID"]]]
    ]

    @Test(arguments: invalidOptions) func invalidProviderSchemaFailsBeforeIO(_ options: JSONValue) async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        await #expect(throws: AIError.self) {
            try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", providerOptions: ["heygen": options]))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func combinedReferenceBoundaryAndUnknownOptionStripping() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        _ = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene",
            inputReferences: Array(repeating: heyGenImage, count: 9) + Array(repeating: heyGenVideo, count: 3),
            providerOptions: ["heygen": ["unknown": true]]))
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["reference_images"]?.arrayValue?.count == 9)
        #expect(body["reference_videos"]?.arrayValue?.count == 3)
        #expect(body["unknown"] == nil)
    }

    @Test func explicitReferenceHighResolutionWithPortraitRatio() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        _ = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", aspectRatio: "9:16", inputReferences: [heyGenImage],
            providerOptions: HeyGenVideoModelOptions(mode: .referenceToVideo, resolution: .twoK).providerOptions))
        #expect(try await heyGenTestRequestBody(transport)["aspect_ratio"] == "9:16")
    }
}
