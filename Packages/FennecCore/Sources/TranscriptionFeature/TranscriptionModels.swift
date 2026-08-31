import Foundation
import PlaybackFeature

public enum TranscriptionError: Error, Equatable, Sendable {
  case invalidModel
  case modelNotInstalled
  case invalidDownload
  case insufficientSpace
  case checksumMismatch
  case invalidMedia
  case invalidTranscript
  case missingAPIKey
  case invalidAPIConfiguration
  case invalidAPIResponse
  case alreadyRunning
}

public struct TranscriptionModelFile: Equatable, Hashable, Sendable {
  public let relativePath: String
  public let url: URL
  public let byteCount: Int64
  public let sha256: String

  public init(relativePath: String, url: URL, byteCount: Int64, sha256: String) {
    self.relativePath = relativePath
    self.url = url
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct TranscriptionModel: Identifiable, Equatable, Hashable, Sendable {
  public enum Engine: String, Codable, Sendable {
    case whisper
    case senseVoice
    case qwen3ASR
    case speakerDiarization
  }

  public let id: String
  public let name: String
  public let detail: String
  public let engine: Engine
  public let languages: [String]
  public let files: [TranscriptionModelFile]
  public let estimatedMemoryMB: Int
  public let isRecommended: Bool
  public let supportsTimeline: Bool
  public let isQuantized: Bool

  public var downloadByteCount: Int64 {
    files.reduce(0) { $0 + $1.byteCount }
  }
}

public enum TranscriptionModels {
  public static let speech = [whisperTiny, whisperBase, senseVoice, qwen3ASR]

  public static func model(id: String) -> TranscriptionModel? {
    (speech + [speaker]).first { $0.id == id }
  }

  public static let whisperTiny = make(
    id: "whisper-tiny-int8",
    name: "Whisper Tiny INT8",
    detail: "Small multilingual model for lower-memory devices",
    engine: .whisper,
    languages: ["multilingual"],
    root:
      "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/65176e2deb88badc814a94058666cadccc29b61c",
    files: [
      (
        "tiny-encoder.int8.onnx", 12_937_772,
        "d24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434"
      ),
      (
        "tiny-decoder.int8.onnx", 89_855_401,
        "d2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925"
      ),
      (
        "tiny-tokens.txt", 816_730,
        "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"
      ),
    ],
    memoryMB: 1_024,
    recommended: false,
    timeline: true
  )

  public static let whisperBase = make(
    id: "whisper-base-int8",
    name: "Whisper Base INT8",
    detail: "Balanced multilingual model with improved accuracy",
    engine: .whisper,
    languages: ["multilingual"],
    root:
      "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/bb53ee204431c90d314c1cc08d28d23e5b7927cc",
    files: [
      (
        "base-encoder.int8.onnx", 29_120_534,
        "0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11"
      ),
      (
        "base-decoder.int8.onnx", 130_672_026,
        "9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d"
      ),
      (
        "base-tokens.txt", 816_730,
        "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"
      ),
    ],
    memoryMB: 1_536,
    recommended: false,
    timeline: true
  )

  public static let senseVoice = make(
    id: "sense-voice-int8",
    name: "SenseVoice Small INT8",
    detail: "Recommended for Mandarin, Cantonese, English, Japanese, and Korean",
    engine: .senseVoice,
    languages: ["zh", "yue", "en", "ja", "ko"],
    root:
      "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07",
    files: [
      (
        "model.int8.onnx", 239_233_841,
        "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
      ),
      ("tokens.txt", 315_894, "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
    ],
    memoryMB: 2_048,
    recommended: true,
    timeline: true
  )

  public static let qwen3ASR = make(
    id: "qwen3-asr-0.6b-int8",
    name: "Qwen3-ASR 0.6B INT8",
    detail: "Large multilingual model for recent high-memory devices",
    engine: .qwen3ASR,
    languages: ["multilingual"],
    root:
      "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a",
    files: [
      (
        "conv_frontend.onnx", 44_148_281,
        "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e"
      ),
      (
        "encoder.int8.onnx", 182_491_662,
        "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9"
      ),
      (
        "decoder.int8.onnx", 755_914_231,
        "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771"
      ),
      (
        "tokenizer/merges.txt", 1_671_853,
        "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
      ),
      (
        "tokenizer/tokenizer_config.json", 12_487,
        "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
      ),
      (
        "tokenizer/vocab.json", 2_776_833,
        "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
      ),
    ],
    memoryMB: 4_096,
    recommended: false,
    timeline: false
  )

  public static let speaker = make(
    id: "speaker-diarization-int8",
    name: "Speaker labels",
    detail: "Optional local speaker segmentation and clustering",
    engine: .speakerDiarization,
    languages: ["language-independent"],
    root:
      "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0",
    files: [
      (
        "segmentation.int8.onnx", 1_540_506,
        "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d"
      ),
      (
        "embedding.onnx", 39_593_761,
        "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b"
      ),
    ],
    memoryMB: 1_536,
    recommended: false,
    timeline: false,
    fileURLs: [
      nil,
      URL(
        string:
          "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
      ),
    ]
  )

  private static func make(
    id: String,
    name: String,
    detail: String,
    engine: TranscriptionModel.Engine,
    languages: [String],
    root: String,
    files: [(String, Int64, String)],
    memoryMB: Int,
    recommended: Bool,
    timeline: Bool,
    fileURLs: [URL?] = []
  ) -> TranscriptionModel {
    TranscriptionModel(
      id: id,
      name: name,
      detail: detail,
      engine: engine,
      languages: languages,
      files: files.enumerated().map { index, file in
        TranscriptionModelFile(
          relativePath: file.0,
          url: fileURLs.indices.contains(index)
            ? fileURLs[index] ?? URL(string: "\(root)/model.int8.onnx")!
            : URL(string: "\(root)/\(file.0)")!,
          byteCount: file.1,
          sha256: file.2
        )
      },
      estimatedMemoryMB: memoryMB,
      isRecommended: recommended,
      supportsTimeline: timeline,
      isQuantized: true
    )
  }
}

public struct TranscriptionSegment: Codable, Equatable, Sendable {
  public let startMilliseconds: Int64
  public let endMilliseconds: Int64
  public let text: String
  public let speaker: String?

  public init(
    startMilliseconds: Int64,
    endMilliseconds: Int64,
    text: String,
    speaker: String? = nil
  ) {
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = text
    self.speaker = speaker
  }
}

public struct SpeakerSegment: Equatable, Sendable {
  public let startMilliseconds: Int64
  public let endMilliseconds: Int64
  public let speaker: Int

  public init(startMilliseconds: Int64, endMilliseconds: Int64, speaker: Int) {
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.speaker = speaker
  }
}

public struct TranscriptionChunk: Equatable, Sendable {
  public let windowStartMilliseconds: Int64
  public let segments: [TranscriptionSegment]
  public let speakers: [SpeakerSegment]

  public init(
    windowStartMilliseconds: Int64,
    segments: [TranscriptionSegment],
    speakers: [SpeakerSegment]
  ) {
    self.windowStartMilliseconds = windowStartMilliseconds
    self.segments = segments
    self.speakers = speakers
  }
}

public struct GeneratedTranscript: Codable, Equatable, Sendable {
  public let modelID: String
  public let createdAt: Date
  public let plainText: String
  public let segments: [TranscriptionSegment]

  public func episodeTranscript() throws -> EpisodeTranscript {
    try EpisodeTranscript(
      plainText: plainText,
      cues: segments.map {
        try TranscriptCue(
          startMilliseconds: $0.startMilliseconds,
          endMilliseconds: $0.endMilliseconds,
          text: $0.text,
          speaker: $0.speaker
        )
      }
    )
  }
}

public enum TranscriptAssembler {
  public static func assemble(
    chunks: [TranscriptionChunk],
    modelID: String,
    createdAt: Date = Date()
  ) throws -> GeneratedTranscript {
    let segments = chunks.flatMap { chunk in
      chunk.segments.compactMap { segment -> TranscriptionSegment? in
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, segment.endMilliseconds > segment.startMilliseconds else {
          return nil
        }
        let speaker = bestSpeaker(for: segment, speakers: chunk.speakers).map {
          "Speaker \($0 + 1)"
        }
        return TranscriptionSegment(
          startMilliseconds: chunk.windowStartMilliseconds + segment.startMilliseconds,
          endMilliseconds: chunk.windowStartMilliseconds + segment.endMilliseconds,
          text: text,
          speaker: speaker
        )
      }
    }.sorted { $0.startMilliseconds < $1.startMilliseconds }
    guard !segments.isEmpty else { throw TranscriptionError.invalidTranscript }
    let plainText = segments.map { segment in
      segment.speaker.map { "\($0): \(segment.text)" } ?? segment.text
    }.joined(separator: "\n")
    return GeneratedTranscript(
      modelID: modelID,
      createdAt: createdAt,
      plainText: plainText,
      segments: segments
    )
  }

  private static func bestSpeaker(
    for segment: TranscriptionSegment,
    speakers: [SpeakerSegment]
  ) -> Int? {
    speakers.compactMap { speaker -> (Int, Int64)? in
      let overlap =
        min(segment.endMilliseconds, speaker.endMilliseconds)
        - max(segment.startMilliseconds, speaker.startMilliseconds)
      return overlap > 0 ? (speaker.speaker, overlap) : nil
    }.max { $0.1 < $1.1 }?.0
  }
}
