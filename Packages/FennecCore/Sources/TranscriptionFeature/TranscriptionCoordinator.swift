import CoreContracts
import Foundation
import LocalData
import PlaybackFeature

public actor TranscriptionCoordinator {
  private let store: LocalDataStore
  private let storageRoot: URL
  private let settingsStore: TranscriptionSettingsStore
  private let modelStore: TranscriptionModelStore
  private let resultStore: TranscriptionResultStore
  private let aiClient: TranscriptAIClient
  private var activeEpisodes = Set<EpisodeKey>()

  public init(
    store: LocalDataStore,
    storageRoot: URL,
    settingsStore: TranscriptionSettingsStore = TranscriptionSettingsStore(),
    modelStore: TranscriptionModelStore? = nil,
    resultStore: TranscriptionResultStore? = nil,
    aiClient: TranscriptAIClient = TranscriptAIClient()
  ) {
    self.store = store
    self.storageRoot = storageRoot
    self.settingsStore = settingsStore
    self.modelStore = modelStore ?? TranscriptionModelStore(storageRoot: storageRoot)
    self.resultStore = resultStore ?? TranscriptionResultStore(storageRoot: storageRoot)
    self.aiClient = aiClient
  }

  public func settings() async -> TranscriptionSettings {
    await settingsStore.load()
  }

  public func saveSettings(_ settings: TranscriptionSettings) async throws {
    try await settingsStore.save(settings)
  }

  public func apiKeyConfigured() async -> Bool {
    await settingsStore.apiKeyConfigured()
  }

  public func saveAPIKey(_ key: String) async throws {
    try await settingsStore.saveAPIKey(key)
  }

  public func clearAPIKey() async {
    await settingsStore.clearAPIKey()
  }

  public func modelStates() async -> [TranscriptionModelState] {
    await modelStore.states()
  }

  public func downloadModel(
    _ model: TranscriptionModel,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    try await modelStore.download(model, progress: progress)
  }

  public func deleteModel(_ model: TranscriptionModel) async throws {
    try await modelStore.delete(model)
  }

  public func generatedTranscript(for key: EpisodeKey) async throws -> EpisodeTranscript? {
    try await resultStore.transcript(for: key)?.episodeTranscript()
  }

  public func aiResult(
    action: TranscriptAIAction,
    for key: EpisodeKey
  ) async throws -> String? {
    try await resultStore.aiResult(action: action, for: key)
  }

  @discardableResult
  public func transcribe(_ episodeKey: EpisodeKey, replace: Bool = false) async throws
    -> EpisodeTranscript
  {
    if !replace, let existing = try await resultStore.transcript(for: episodeKey) {
      return try existing.episodeTranscript()
    }
    guard activeEpisodes.insert(episodeKey).inserted else {
      throw TranscriptionError.alreadyRunning
    }
    defer { activeEpisodes.remove(episodeKey) }
    let settings = await settingsStore.load()
    guard let model = TranscriptionModels.model(id: settings.selectedModelID) else {
      throw TranscriptionError.invalidModel
    }
    let modelDirectory = try await modelStore.modelDirectory(model)
    let speakerDirectory: URL?
    if settings.speakerLabelsEnabled,
      await modelStore.isInstalled(TranscriptionModels.speaker)
    {
      speakerDirectory = try await modelStore.modelDirectory(TranscriptionModels.speaker)
    } else {
      speakerDirectory = nil
    }
    let mediaURL = try await localMediaURL(for: episodeKey)
    let transcriber = try SherpaTranscriber(
      model: model,
      modelDirectory: modelDirectory,
      speakerDirectory: speakerDirectory
    )
    var chunks: [TranscriptionChunk] = []
    try await AVFoundationAudioDecoder().decode(url: mediaURL) { window in
      chunks.append(try transcriber.transcribe(window))
    }
    let generated = try TranscriptAssembler.assemble(chunks: chunks, modelID: model.id)
    try await resultStore.save(generated, for: episodeKey)
    return try generated.episodeTranscript()
  }

  public func handleDownloadCompleted(_ episodeKey: EpisodeKey) async {
    let settings = await settingsStore.load()
    guard
      settings.transcribeAfterDownload,
      let model = TranscriptionModels.model(id: settings.selectedModelID),
      await modelStore.isInstalled(model)
    else { return }
    _ = try? await transcribe(episodeKey)
  }

  public func generateAI(
    action: TranscriptAIAction,
    transcript: EpisodeTranscript,
    for episodeKey: EpisodeKey
  ) async throws -> String {
    let settings = await settingsStore.load()
    let apiKey = try await settingsStore.apiKey()
    let result = try await aiClient.generate(
      action: action,
      transcript: transcript.plainText,
      settings: settings,
      apiKey: apiKey
    )
    try await resultStore.saveAIResult(result, action: action, for: episodeKey)
    return result
  }

  private func localMediaURL(for key: EpisodeKey) async throws -> URL {
    guard
      let record = try await store.localMediaRecord(for: key),
      record.state == .completed,
      let relativePath = record.localRelativePath
    else { throw TranscriptionError.invalidMedia }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !relativePath.hasPrefix("/"),
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw TranscriptionError.invalidMedia }
    let url = components.reduce(storageRoot) {
      $0.appendingPathComponent(String($1), isDirectory: false)
    }
    let rootPath = storageRoot.resolvingSymlinksInPath().standardizedFileURL.path
    let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard
      filePath.hasPrefix(rootPath + "/"),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      Int64(values.fileSize ?? -1) == record.downloadedBytes
    else { throw TranscriptionError.invalidMedia }
    return url
  }
}
