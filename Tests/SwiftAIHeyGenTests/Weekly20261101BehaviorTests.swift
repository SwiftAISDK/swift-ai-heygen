import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIHeyGen

@Suite struct Weekly20261101HeyGenBehaviorTests {
    @Test(arguments: [1.0, 16, 30, 31, 60], ["text_to_video", "image_to_video", "reference_to_video"])
    func longAndShortPositiveDurationsReachTheProvider(_ duration: Double, _ mode: String) async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        var request = VideoGenerationRequest(prompt: "Scene", aspectRatio: "16:9", durationSeconds: duration, providerOptions: ["heygen": ["mode": .string(mode), "promptEnhancement": "ultraquality"]])
        if mode == "image_to_video" { request.image = heyGenImage }
        if mode == "reference_to_video" { request.inputReferences = [heyGenVideo] }
        _ = try await heyGenTestStart(transport, request: request)
        let body = try await heyGenTestRequestBody(transport)
        #expect(body["duration"] == .number(duration))
        #expect(body["mode"] == .string(mode))
        #expect(body["prompt_enhancement"] == "ultraquality")
    }

    @Test(arguments: ["480p", "768p", "1080p", "2k"])
    func thirtySecondClipsSupportEveryResolution(_ resolution: String) async throws {
        let transport = RecordingTransport(response: jsonResponse(heyGenCreated))
        _ = try await heyGenTestStart(transport, request: .init(prompt: "Scene", aspectRatio: "16:9", durationSeconds: 30, providerOptions: ["heygen": ["resolution": .string(resolution), "promptEnhancement": "quality"]]))
        #expect(try await heyGenTestRequestBody(transport)["duration"] == 30)
    }

    @Test func providerDurationErrorsAreNotClampedOrRetried() async throws {
        let transport = RecordingTransport(response: .init(statusCode: 400, body: Data(#"{"error":{"code":"invalid_parameter","message":"Duration exceeds the limit for these settings","param":"duration"}}"#.utf8)))
        do { _ = try await heyGenTestStart(transport, request: .init(prompt: "Scene", durationSeconds: 31)); Issue.record("Expected provider failure") }
        catch let AIError.apiCall(error) { #expect(error.statusCode == 400); #expect(!error.isRetryable); #expect(error.message?.contains("Duration exceeds") == true) }
        #expect(await transport.requests().count == 1)
        #expect(try await heyGenTestRequestBody(transport)["duration"] == 31)
    }
}
