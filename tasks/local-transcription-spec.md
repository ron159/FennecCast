# Spec: Local transcription and transcript AI

## Capability map

| Module id | Responsibility | Depends on |
|---|---|---|
| transcription-core | Model catalog, download state, transcript/job contracts | — |
| transcription-engine | AVFoundation decoding, sherpa-onnx inference, optional diarization | transcription-core |
| transcription-ui | Model management, manual and post-download triggers, timed SwiftUI transcript | transcription-core, transcription-engine |
| transcript-ai | OpenAI-compatible translation and summary with Keychain credentials | transcription-core |

Build order: transcription-core → transcription-engine → transcript-ai → transcription-ui.

## Objective

Add opt-in, fully on-device speech-to-text for downloaded podcast episodes. Users choose and download quantized models, start transcription manually, or enable it after a media download. Generated transcripts persist locally with seekable time ranges and optional speaker labels. A user-supplied OpenAI-compatible or DeepSeek key enables translation and summary of generated text.

## Tech stack

- Swift 6, SwiftUI, iOS 17+, GRDB 7.11.1.
- sherpa-onnx 1.13.6 Swift Package/XCFramework.
- AVFoundation for bounded media decoding and conversion to 16 kHz mono float PCM.
- URLSession downloads and API calls; Keychain for API credentials.

## Commands

- Package tests: `swift test --package-path Packages/FennecCore`
- Format lint: `swift format lint --strict --recursive Sources Packages/FennecCore/Sources Packages/FennecCore/Tests`
- App build: `xcodebuild -project FennecCast.xcodeproj -scheme FennecCast -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

## Project structure

- `Packages/FennecCore/Sources/TranscriptionFeature` owns contracts, catalog, model files, job/result storage, inference, and AI client.
- `Packages/FennecCore/Tests/TranscriptionFeatureTests` covers pure and boundary behavior.
- `Sources/App` composes the feature into the existing environment, settings, episode detail, download completion, and player-seeking UI.

## Code style

Use Sendable value types and small actors for mutable file/job/network state. Match existing SwiftUI Form, Section, toolbar, task, and alert patterns. Keep English and Simplified Chinese localizations in the current string catalogs.

## Testing strategy

- Unit-test the catalog, safe paths, timestamp grouping, speaker overlap mapping, JSON persistence, and OpenAI-compatible request/response parsing.
- Inject URLSession/model runner/media decoder boundaries so package tests need neither model weights nor network.
- Build the app after package tests to verify SwiftPM/Xcode integration.

## Boundaries

- Always: require opt-in downloads/automation, verify file size and SHA-256, use Keychain for keys, chunk long audio, preserve publisher transcripts.
- Ask first: publishing generated text to a feed or sync service, changing model revisions/digests.
- Never: bundle weights in the app, upload audio, call a text AI provider without a user action, place keys in UserDefaults/logs/files.

## Success criteria

- Whisper tiny INT8, Whisper base INT8, SenseVoice INT8, and Qwen3-ASR 0.6B INT8 are selectable with progress/delete/retry and resource warnings.
- Manual and opt-in post-download transcription work for local episode media.
- Generated transcript storage survives relaunch, shows timed rows that seek playback, and shows optional `Speaker N` labels.
- OpenAI-compatible and DeepSeek presets support translation and summary with a user key.
- Cancellation, missing media/model, storage, corrupt model, decoder, inference, and API errors are visible and retryable.

## Open questions

None blocking. The user requested implementation without intermediate design confirmation. Automatic transcription and diarization are disabled by default.
