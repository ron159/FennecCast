# Implementation Plan: iOS local transcription

## Architecture decisions

- Add one `TranscriptionFeature` package target backed by sherpa-onnx 1.13.6.
- Persist model/job/result artifacts below Application Support and add only lightweight state needed for UI observation.
- Decode with AVFoundation into bounded 16 kHz mono windows.
- Trigger user-started work immediately and use background task assertions only to finish safe checkpoints; persist interruption state for retry.
- Store the AI key in Keychain and keep the provider base URL/model in non-secret settings.

## Task list

1. Add catalog/contracts/result store and RED unit tests.
2. Add sherpa adapter, audio decoder, timestamp/diarization mapping and tests.
3. Add model download/transcription coordinators with retryable state.
4. Compose the feature into app environment and download completion.
5. Add native model settings and episode/timed transcript UI.
6. Add OpenAI-compatible/DeepSeek translation and summary.
7. Run package tests, format lint, simulator build, and requirement audit.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| iOS suspends long work | Partial transcript | Persist completed windows and resume explicitly |
| Large model memory pressure | Termination | Resource warnings, bounded windows, smaller default |
| SwiftPM binary dependency drift | Broken build | Pin sherpa-onnx exact 1.13.6 |
| Transcript source ambiguity | User confusion | Label generated text and keep publisher transcript priority |
