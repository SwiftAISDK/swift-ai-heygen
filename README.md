<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-heygen 1.2.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-heygen.git", from: "1.2.0")
```

Products: `SwiftAIHeyGen`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# SwiftAIHeyGen

Swift-native port of `@ai-sdk/heygen` **3.0.25**: asynchronous video generation
and multimodal Decision V4. Maintained in the canonical SwiftAISDK repository and
exported as an independent Swift package.

## Setup

Use the `SwiftAIHeyGen` product. For core operations, also import the `SwiftAI`
product from `swift-ai-core` 1.4.0 or later. The package requires Swift 6.3,
macOS 12 or iOS 15.

```swift
import SwiftAIHeyGen

let provider = try HeyGenProvider(configuration: .init(apiKey: "..."))
```

Set `HEYGEN_API_KEY`, provide `apiKey`, or use `apiKeyProvider` to supply a fresh
key before each authenticated request. Credentials are resolved lazily for both
video and Decision. A missing key now fails the request; the released throwing
initializer signature remains available. Headers use `x-api-key` and the
versioned `ai-sdk-heygen/3.0.25` user agent. Provider and call headers override
defaults case-insensitively, with call headers taking precedence.

Settings also accept a custom `baseURL` (default `https://api.heygen.com`), headers,
query parameters, a deterministic environment map and an injected `AITransport`.
`createHeyGen(configuration:)`, the default `heygen` instance, and
`AIProviders.heyGen(configuration:)` expose the same provider.

## Decide from text, JSON, images and video

```swift
import Foundation
import SwiftAI
import SwiftAIHeyGen

let provider = try createHeyGen()
let model = try provider.decisionModel("heygen-decision-1-turbo")
let result = try await model.doDecide(.init(
    state: [
        .text("Which team should handle this video problem?"),
        .file(mediaType: "video/mp4", data: .url(URL(string: "https://example.com/clip.mp4")!)),
        .file(mediaType: "image/png", data: .reference("your-heygen-asset-id"))
    ],
    questions: [
        "blocked": .boolean(instructions: "Is the customer unable to work?"),
        "team": .choice(
            instructions: "Which team should handle this?",
            criteria: ["video": "Rendering", "account": "Access", "billing": "Payments"]
        ),
        "impact": .score(
            instructions: "How much does this affect the customer?",
            criteria: ["Cosmetic", "Slower", "Blocked"]
        )
    ]
))

let confidence = result.providerMetadata["heygen"]?["confidence"]
```

Decision models call `/v3/models/decisions`. Known IDs are `heygen-decision-1`
and `heygen-decision-1-turbo`; custom IDs pass through unchanged. `decision(_:)`
is a native alias for `decisionModel(_:)`.

Requests support 1–400 questions. Names must be nonempty, without colons or
newlines or leading/trailing whitespace. Choice questions allow 1–255 criteria;
score questions allow 1–10 non-null levels, including a single-level score.
Box questions are unsupported. `maxOutputTokens`, `reasoning` and all HeyGen
provider-specific options produce warnings and are omitted from the request.

Decision accepts up to four images and one video. File inputs may contain `Data`,
existing base64 text, HTTPS URLs or provider-native asset ID strings. Full media
types pass through; `image`/`video` types are detected from inline bytes when
possible. Files are grouped by kind with stable `image-1`/`video-1` names and
preserve order within each group. The model reads images, then video, then state.
Text and JSON remain in the ordered state. A single string/object/array is sent
directly; numbers, booleans and null remain inside an array. Other file types and
non-HTTPS URLs fail before network I/O.

Results preserve boolean probabilities, choice/score probabilities and full
precision. The adapter requires exactly one answer per question. Metadata under
`providerMetadata["heygen"]` preserves `requestId`, per-answer `confidence`,
JSON-valued score `legend` entries and `answerWarnings`. Ancillary response IDs,
model names and usage may be omitted. Response metadata preserves headers and
the complete wire body. Native token counters are integral; nonintegral or
overflowing wire values remain in the raw response and are omitted from typed
usage. HTTP failures retain error codes, parameter names, status and headers.
Pass `abortSignal` in options to propagate cancellation.

`heyGenDecisionModelIDs`, `heyGenDecisionModelLimits` and
`getHeyGenDecisionModelEntry(_:)` expose the published Decision limits and
descriptive capabilities, including for custom model IDs.

## Generate video

The existing `video(_:)` and `videoModel(_:)` APIs retain asynchronous
start/status behavior. `HeyGenVideoModel` implements `AsyncVideoModel`; the core
`AI.generateVideo` operation polls it automatically. Video generation continues
to support text-to-video, first-frame images, typed image/video/audio references,
resolutions and prompt enhancement through `HeyGenVideoModelOptions`.

Run the standalone suite from the canonical checkout:

```sh
swift test --package-path Packages/swift-ai-heygen --no-parallel
```

Matching-release Decision tests retain the original illustrative fixture and
portable request, asset, limit, response and error scenarios. JavaScript Workflow
serialization is excluded. The shared Swift file-data enum has no inline text-file
or foreign-provider reference-map cases, so those two invalid JS input shapes
cannot compile; direct native asset IDs and other invalid media cases are tested.
Per-file/scenario dispositions and provenance are in `Porting/integration.json`.
Fixture-backed tests do not establish paid or live-service verification.

The canonical repository owns all edits. Distribution manifests and repositories
are generated from the catalog; see `Porting/map.json` and the canonical provider guide.

See [provider usage and capabilities](https://github.com/SwiftAISDK/SwiftAISDK/blob/main/docs-site/scripts/provider-guides/heygen.md) for authentication, options and supported surfaces.
