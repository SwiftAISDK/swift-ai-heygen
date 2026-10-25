@testable import SwiftAIHeyGen
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

/// Status, persistence, failure, and abort fixtures from heygen-video-model.test.ts.
@Suite struct HeyGenVideoOperationTests {
    @Test(arguments: ["pending", "processing"]) func pendingStatesKeepOperationAndReportedMetadata(_ state: String) async throws {
        let transport = RecordingTransport(response: jsonResponse("{\"data\":{\"status\":\"\(state)\",\"timings\":{\"inference\":0}}}"))
        let result = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation))
        guard case let .pending(warnings, metadata, response) = result else { Issue.record("Expected pending"); return }
        #expect(warnings.isEmpty)
        #expect(metadata["heygen"]?["videoId"] == "video-1")
        #expect(metadata["heygen"]?["timings"] == ["inference": 0])
        #expect(response.modelID == "heygen-video-1")
    }

    @Test func completedSignedURLMetadataAndNoDownload() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCompleted, headers: ["x-status": "done"]))
        let status = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation))
        guard case let .completed(result) = status else { Issue.record("Expected completed"); return }
        #expect(result.urls == ["https://resource2.heygen.ai/video.mp4"])
        #expect(result.base64Videos.isEmpty)
        #expect(result.mediaType == "video/mp4" && result.operationID == "video-1")
        #expect(result.providerMetadata == ["heygen": ["videos": [[
            "videoId": "video-1", "mode": "text_to_video", "resolution": "768p", "duration": 5,
            "width": 1344, "height": 768, "aspectRatio": "16:9", "seed": 0
        ]]]])
        #expect(result.responseMetadata.headers["x-status"] == "done")
        #expect(await transport.requests().count == 1)
    }

    @Test func persistedOperationRestoresResolutionAndUsesReportedDurationAndTiming() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(heyGenCreated), jsonResponse(#"{"data":{"status":"completed","video_url":"https://cdn.example.com/out.mp4","duration":5.042,"timings":{"inference":3.7}}}"#)])
        let started = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", durationSeconds: 5,
            providerOptions: HeyGenVideoModelOptions(resolution: .twoK).providerOptions))
        let operation = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(started.operation))
        let model = try heyGenTestModel(transport)
        let status = try await model.videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: operation))
        guard case let .completed(result) = status else { Issue.record("Expected completed"); return }
        let video = result.providerMetadata["heygen"]?["videos"]?[0]
        #expect(video?["resolution"] == "2k" && video?["duration"] == 5.042)
        #expect(video?["timings"] == ["inference": 3.7])
        #expect(result.providerMetadata["heygen"]?["tokens"] == nil)
        #expect(result.providerMetadata["heygen"]?["credits"] == nil)
    }

    @Test func absentAndNullOptionalMetadataAreOmitted() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"data":{"status":"completed","video_url":"https://cdn.example.com/out.mp4","duration":null,"width":null,"height":null,"aspect_ratio":null,"seed":null,"timings":{"inference":null}}}"#))
        guard case let .completed(result) = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation)) else { Issue.record("Expected completed"); return }
        #expect(result.providerMetadata == ["heygen": ["videos": [heyGenOperation]]])
    }

    @Test(arguments: ["failed", "cancelled"]) func terminalErrorsKeepFailureCodeAndZeroTiming(_ status: String) async throws {
        let transport = RecordingTransport(response: jsonResponse("{\"data\":{\"status\":\"\(status)\",\"failure_code\":\"generation_failed\",\"failure_message\":\"Generation did not finish.\",\"timings\":{\"inference\":0}}}"))
        guard case let .failed(message, metadata, _) = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation)) else { Issue.record("Expected failed"); return }
        #expect(message == "Generation did not finish. (generation_failed)")
        #expect(metadata["heygen"]?["failureCode"] == "generation_failed")
        #expect(metadata["heygen"]?["timings"] == ["inference": 0])
    }

    @Test func failureWithoutMessageUsesStatusDescription() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"data":{"status":"failed"}}"#))
        guard case let .failed(message, _, _) = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation)) else { Issue.record("Expected failed"); return }
        #expect(message == "HeyGen video generation failed")
    }

    @Test(arguments: [#"{"data":{"status":"completed"}}"#, #"{"data":{"status":"completed","video_url":""}}"#, #"{"data":{"status":"unexpected"}}"#])
    func unusableStatusIsAnInvalidResponse(_ json: String) async throws {
        let transport = RecordingTransport(response: jsonResponse(json))
        do {
            _ = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation))
            Issue.record("Expected invalid response")
        } catch AIError.invalidResponse { } catch { Issue.record("Unexpected error \(error)") }
    }

    @Test(arguments: [JSONValue.null, [:], ["videoId": "", "mode": "text_to_video", "resolution": "768p"], ["videoId": "v", "mode": "invalid", "resolution": "768p"], ["videoId": "v", "mode": "text_to_video", "resolution": "4k"]])
    func invalidOperationsFailBeforeIO(_ operation: JSONValue) async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCompleted))
        await #expect(throws: AIError.self) {
            try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: operation))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func repeatedStatusRefreshesSignedURL() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(heyGenCompleted), jsonResponse(#"{"data":{"status":"completed","video_url":"https://resource2.heygen.ai/video.mp4?signature=new"}}"#)])
        let model = try heyGenTestModel(transport)
        _ = try await model.videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation))
        guard case let .completed(result) = try await model.videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation)) else { Issue.record("Expected completed"); return }
        #expect(result.urls == ["https://resource2.heygen.ai/video.mp4?signature=new"])
        #expect(await transport.requests().count == 2)
    }

    @Test(arguments: ["video/a?x=# fragment", ".", ".."]) func operationIDStaysInOnePathComponent(_ id: String) async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"data":{"status":"pending"}}"#))
        var operation = try #require(heyGenOperation.objectValue); operation["videoId"] = .string(id)
        _ = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: .object(operation)))
        let call = try #require(await transport.requests().first)
        #expect(call.url.absoluteString.hasPrefix("https://api.heygen.com/v3/models/videos/"))
        #expect(call.url.query == nil && call.url.fragment == nil)
        if id == "." || id == ".." { #expect(call.url.absoluteString.hasSuffix(id.replacingOccurrences(of: ".", with: "%2E"))) }
        else { #expect(call.url.absoluteString.contains("video%2Fa%3Fx%3D%23%20fragment")) }
    }

    @Test(arguments: [true, false]) func apiErrorsKeepMessageBodyHeadersAndRetryability(_ start: Bool) async throws {
        let raw = #"{"error":{"code":"invalid_parameter","message":"Invalid duration","param":"duration"}}"#
        let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 400, headers: ["x-error": "invalid"], body: Data(raw.utf8)))
        do {
            let model = try heyGenTestModel(transport)
            if start { _ = try await model.startVideoGeneration(VideoGenerationOperationStartRequest(request: VideoGenerationRequest(prompt: "Scene"))) }
            else { _ = try await model.videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation)) }
            Issue.record("Expected API error")
        } catch AIError.apiCall(let error) {
            #expect(error.message == "Invalid duration (invalid_parameter) [duration]")
            #expect(error.statusCode == 400 && !error.isRetryable)
            #expect(error.responseHeaders["x-error"] == "invalid" && error.responseBody == raw)
            #expect(error.url?.hasPrefix("https://api.heygen.com/v3/models/videos") == true)
            if start { #expect(error.requestBody?["model"] == "heygen-video-1") }
        }
    }

    @Test(arguments: [#"{"data":{"status":"pending"}}"#, #"{"data":{"video_id":""}}"#, #"{"data":{"video_id":7}}"#, "not json"])
    func malformedCreationIsNonretryableAPICallError(_ json: String) async throws {
        let transport = RecordingTransport(response: jsonResponse(json))
        do { _ = try await heyGenTestStart(transport); Issue.record("Expected API error") }
        catch AIError.apiCall(let error) { #expect(error.statusCode == 200 && !error.isRetryable && error.responseBody == json) }
    }

    @Test(arguments: [#"{"data":{"status":7}}"#, #"{"data":{"status":"pending","duration":"5"}}"#, #"{"data":{"status":"pending","timings":{"inference":"0"}}}"#, #"{"data":{"status":"pending","video_url":7}}"#])
    func malformedStatusSchemaIsRejected(_ json: String) async throws {
        let transport = RecordingTransport(response: jsonResponse(json))
        do { _ = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation)); Issue.record("Expected API error") }
        catch AIError.apiCall(let error) { #expect(error.statusCode == 200 && !error.isRetryable) }
    }

    @Test func pollingFacadeConcatenatesVideosAndFallsBackFromWebhook() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(heyGenCreated), jsonResponse(#"{"data":{"status":"processing"}}"#), jsonResponse(heyGenCompleted)])
        let result = try await AI.generateVideo(model: heyGenTestModel(transport), request: VideoGenerationRequest(prompt: "Scene"), retryPolicy: .none,
            poll: VideoGenerationPollOptions(intervalMilliseconds: 0, timeoutMilliseconds: 10_000, delay: { _, _ in }),
            webhook: { throw AIError.invalidArgument(argument: "webhook", message: "Must not invoke unsupported webhook") })
        #expect(result.urls.count == 1 && result.providerMetadata["heygen"]?["videos"]?.arrayValue?.count == 1)
        #expect(result.warnings.contains { $0.feature == "webhook" })
        let calls = await transport.requests()
        #expect(calls.map(\.method) == ["POST", "GET", "GET"])
        #expect(calls[0].headers["idempotency-key"]?.hasPrefix("aisdk_vid_") == true)
    }

    @Test func facadeStartRetriesUseTheSameIdempotencyKey() async throws {
        let transport = RecordingTransport(responses: [AIHTTPResponse(statusCode: 503, body: Data(#"{"error":{"message":"Try again"}}"#.utf8)), jsonResponse(heyGenCreated)])
        _ = try await AI.startVideo(model: heyGenTestModel(transport), request: VideoGenerationRequest(prompt: "Scene"),
            retryPolicy: AIRetryPolicy(maxRetries: 1, initialDelayNanoseconds: 0))
        let calls = await transport.requests()
        #expect(calls.count == 2 && calls[0].headers["idempotency-key"] == calls[1].headers["idempotency-key"])
    }

    @Test func abortedRequestsDoNotStartOrCheckStatus() async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        let controller = AIAbortController(); controller.abort(reason: "Cancelled")
        await #expect(throws: AIAbortError.self) {
            try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", abortSignal: controller.signal))
        }
        await #expect(throws: AIAbortError.self) {
            try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: heyGenOperation, abortSignal: controller.signal))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func abortSignalReachesTransportForBothOperations() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(heyGenCreated), jsonResponse(heyGenCompleted)])
        let controller = AIAbortController()
        let started = try await heyGenTestStart(transport, request: VideoGenerationRequest(prompt: "Scene", abortSignal: controller.signal))
        _ = try await heyGenTestModel(transport).videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: started.operation, abortSignal: controller.signal))
        #expect(await transport.requests().allSatisfy { $0.abortSignal === controller.signal })
    }
}
