import Testing

@testable import TranscriptionFeature

@Test func catalogHasSelectableQuantizedModelsAndSeparateSpeakerPack() {
  #expect(TranscriptionModels.speech.count == 4)
  #expect(TranscriptionModels.speech.allSatisfy { $0.isQuantized })
  #expect(TranscriptionModels.speech.contains { $0.engine == .qwen3ASR })
  #expect(TranscriptionModels.speaker.engine == .speakerDiarization)
  #expect(!TranscriptionModels.speech.contains(TranscriptionModels.speaker))
}

@Test func assemblerOffsetsWindowsAndAppliesBestSpeakerOverlap() throws {
  let transcript = try TranscriptAssembler.assemble(
    chunks: [
      TranscriptionChunk(
        windowStartMilliseconds: 0,
        segments: [
          TranscriptionSegment(startMilliseconds: 1_000, endMilliseconds: 4_000, text: "Hello"),
          TranscriptionSegment(startMilliseconds: 4_000, endMilliseconds: 7_000, text: "world"),
        ],
        speakers: [
          SpeakerSegment(startMilliseconds: 500, endMilliseconds: 4_500, speaker: 0),
          SpeakerSegment(startMilliseconds: 4_500, endMilliseconds: 7_500, speaker: 1),
        ]
      ),
      TranscriptionChunk(
        windowStartMilliseconds: 300_000,
        segments: [
          TranscriptionSegment(startMilliseconds: 0, endMilliseconds: 2_000, text: "Next")
        ],
        speakers: []
      ),
    ],
    modelID: "whisper-tiny-int8"
  )

  #expect(transcript.segments.map(\.startMilliseconds) == [1_000, 4_000, 300_000])
  #expect(transcript.segments.map(\.speaker) == ["Speaker 1", "Speaker 2", nil])
  #expect(transcript.plainText == "Speaker 1: Hello\nSpeaker 2: world\nNext")
}

@Test func generatedTranscriptRejectsEmptyContent() {
  #expect(throws: TranscriptionError.invalidTranscript) {
    try TranscriptAssembler.assemble(chunks: [], modelID: "model")
  }
}
