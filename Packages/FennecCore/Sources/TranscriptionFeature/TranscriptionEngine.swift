import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import SherpaOnnx

struct AudioWindow: Sendable {
  let startMilliseconds: Int64
  let samples: [Float]
}

struct AVFoundationAudioDecoder {
  static let sampleRate = 16_000
  static let windowSampleCount = sampleRate * 5 * 60

  func decode(
    url: URL,
    onWindow: (AudioWindow) throws -> Void
  ) async throws {
    guard url.isFileURL else { throw TranscriptionError.invalidMedia }
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw TranscriptionError.invalidMedia
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Self.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw TranscriptionError.invalidMedia }
    reader.add(output)
    guard reader.startReading() else { throw TranscriptionError.invalidMedia }

    var pending: [Float] = []
    pending.reserveCapacity(Self.windowSampleCount)
    var emittedSamples: Int64 = 0
    while let sampleBuffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard
        let block = CMSampleBufferGetDataBuffer(sampleBuffer),
        CMBlockBufferGetDataLength(block) % MemoryLayout<Float>.size == 0
      else {
        reader.cancelReading()
        throw TranscriptionError.invalidMedia
      }
      let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
      guard count > 0 else { continue }
      var values = Array(repeating: Float.zero, count: count)
      let status = values.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(
          block,
          atOffset: 0,
          dataLength: bytes.count,
          destination: bytes.baseAddress!
        )
      }
      guard status == noErr else {
        reader.cancelReading()
        throw TranscriptionError.invalidMedia
      }
      pending.append(contentsOf: values)
      while pending.count >= Self.windowSampleCount {
        let samples = Array(pending.prefix(Self.windowSampleCount))
        pending.removeFirst(Self.windowSampleCount)
        try onWindow(
          AudioWindow(
            startMilliseconds: emittedSamples * 1_000 / Int64(Self.sampleRate),
            samples: samples
          )
        )
        emittedSamples += Int64(samples.count)
      }
    }
    guard reader.status == .completed else { throw TranscriptionError.invalidMedia }
    if !pending.isEmpty {
      try onWindow(
        AudioWindow(
          startMilliseconds: emittedSamples * 1_000 / Int64(Self.sampleRate),
          samples: pending
        )
      )
    }
  }
}

final class SherpaTranscriber {
  private static let sampleRate = 16_000
  private static let chunkSampleCount = sampleRate * 30

  private let model: TranscriptionModel
  private let recognizer: SherpaOnnxOfflineRecognizer
  private let diarizer: SherpaOnnxOfflineSpeakerDiarizationWrapper?

  init(
    model: TranscriptionModel,
    modelDirectory: URL,
    speakerDirectory: URL?
  ) throws {
    guard model.engine != .speakerDiarization else {
      throw TranscriptionError.invalidModel
    }
    self.model = model
    let threads = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 4)
    self.recognizer = try Self.makeRecognizer(
      model: model,
      modelDirectory: modelDirectory,
      threads: threads
    )
    if let speakerDirectory {
      var speakerConfig = sherpaOnnxOfflineSpeakerDiarizationConfig(
        segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
          pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
            model: speakerDirectory.appendingPathComponent("segmentation.int8.onnx").path
          ),
          numThreads: threads
        ),
        embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
          model: speakerDirectory.appendingPathComponent("embedding.onnx").path,
          numThreads: threads
        ),
        clustering: sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: 0.5)
      )
      self.diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &speakerConfig)
    } else {
      self.diarizer = nil
    }
  }

  private static func makeRecognizer(
    model: TranscriptionModel,
    modelDirectory: URL,
    threads: Int
  ) throws -> SherpaOnnxOfflineRecognizer {
    switch model.engine {
    case .whisper:
      let prefix = model.id.contains("tiny") ? "tiny" : "base"
      let modelConfig = sherpaOnnxOfflineModelConfig(
        tokens: modelDirectory.appendingPathComponent("\(prefix)-tokens.txt").path,
        whisper: sherpaOnnxOfflineWhisperModelConfig(
          encoder: modelDirectory.appendingPathComponent("\(prefix)-encoder.int8.onnx").path,
          decoder: modelDirectory.appendingPathComponent("\(prefix)-decoder.int8.onnx").path,
          language: "",
          task: "transcribe",
          enableTokenTimestamps: true,
          enableSegmentTimestamps: true
        ),
        numThreads: threads,
        modelType: "whisper"
      )
      var config = sherpaOnnxOfflineRecognizerConfig(
        featConfig: sherpaOnnxFeatureConfig(sampleRate: Self.sampleRate, featureDim: 80),
        modelConfig: modelConfig
      )
      return SherpaOnnxOfflineRecognizer(config: &config)
    case .senseVoice:
      let modelConfig = sherpaOnnxOfflineModelConfig(
        tokens: modelDirectory.appendingPathComponent("tokens.txt").path,
        numThreads: threads,
        modelType: "sense_voice",
        senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
          model: modelDirectory.appendingPathComponent("model.int8.onnx").path,
          language: "auto",
          useInverseTextNormalization: true
        )
      )
      var config = sherpaOnnxOfflineRecognizerConfig(
        featConfig: sherpaOnnxFeatureConfig(sampleRate: Self.sampleRate, featureDim: 80),
        modelConfig: modelConfig
      )
      return SherpaOnnxOfflineRecognizer(config: &config)
    case .qwen3ASR:
      let modelConfig = sherpaOnnxOfflineModelConfig(
        tokens: "",
        numThreads: threads,
        modelType: "qwen3_asr",
        qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(
          convFrontend: modelDirectory.appendingPathComponent("conv_frontend.onnx").path,
          encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx").path,
          decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx").path,
          tokenizer: modelDirectory.appendingPathComponent("tokenizer", isDirectory: true).path,
          maxTotalLen: 1_024,
          maxNewTokens: 512
        )
      )
      var config = sherpaOnnxOfflineRecognizerConfig(
        featConfig: sherpaOnnxFeatureConfig(sampleRate: Self.sampleRate, featureDim: 80),
        modelConfig: modelConfig
      )
      return SherpaOnnxOfflineRecognizer(config: &config)
    case .speakerDiarization:
      throw TranscriptionError.invalidModel
    }
  }

  func transcribe(_ window: AudioWindow) throws -> TranscriptionChunk {
    let speakers =
      diarizer?.process(samples: window.samples).map {
        SpeakerSegment(
          startMilliseconds: Int64(($0.start * 1_000).rounded()),
          endMilliseconds: Int64(($0.end * 1_000).rounded()),
          speaker: $0.speaker
        )
      } ?? []
    var segments: [TranscriptionSegment] = []
    var start = 0
    while start < window.samples.count {
      try Task.checkCancellation()
      let end = min(start + Self.chunkSampleCount, window.samples.count)
      let samples = Array(window.samples[start..<end])
      let chunkStart = Int64(start) * 1_000 / Int64(Self.sampleRate)
      let chunkDuration = Int64(samples.count) * 1_000 / Int64(Self.sampleRate)
      let result = recognizer.decode(samples: samples, sampleRate: Self.sampleRate)
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if model.engine == .whisper,
        result.segmentCount > 0,
        result.segmentTimestamps.count == result.segmentTexts.count,
        result.segmentDurations.count == result.segmentTexts.count
      {
        for index in result.segmentTexts.indices {
          let segmentText = result.segmentTexts[index]
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !segmentText.isEmpty else { continue }
          let relativeStart = Int64((result.segmentTimestamps[index] * 1_000).rounded())
          let duration = Int64((result.segmentDurations[index] * 1_000).rounded())
          segments.append(
            TranscriptionSegment(
              startMilliseconds: chunkStart + max(0, relativeStart),
              endMilliseconds: chunkStart + min(chunkDuration, max(1, relativeStart + duration)),
              text: segmentText
            )
          )
        }
      } else if !text.isEmpty {
        segments.append(
          TranscriptionSegment(
            startMilliseconds: chunkStart,
            endMilliseconds: chunkStart + max(1, chunkDuration),
            text: text
          )
        )
      }
      start = end
    }
    return TranscriptionChunk(
      windowStartMilliseconds: window.startMilliseconds,
      segments: segments,
      speakers: speakers
    )
  }
}
