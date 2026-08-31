import CoreContracts
import CryptoKit
import Foundation
import Security

public struct TranscriptionSettings: Codable, Equatable, Sendable {
  public var selectedModelID: String
  public var transcribeAfterDownload: Bool
  public var speakerLabelsEnabled: Bool
  public var apiBaseURL: String
  public var apiModel: String
  public var translationTarget: String

  public init(
    selectedModelID: String = TranscriptionModels.senseVoice.id,
    transcribeAfterDownload: Bool = false,
    speakerLabelsEnabled: Bool = false,
    apiBaseURL: String = "https://api.openai.com/v1",
    apiModel: String = "gpt-4.1-mini",
    translationTarget: String = "Simplified Chinese"
  ) {
    self.selectedModelID = selectedModelID
    self.transcribeAfterDownload = transcribeAfterDownload
    self.speakerLabelsEnabled = speakerLabelsEnabled
    self.apiBaseURL = apiBaseURL
    self.apiModel = apiModel
    self.translationTarget = translationTarget
  }
}

public actor TranscriptionSettingsStore {
  private static let settingsKey = "localTranscription.settings.v1"
  private static let keychainService = "com.fenneccast.transcription"
  private static let keychainAccount = "openai-compatible-api-key"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> TranscriptionSettings {
    guard
      let data = defaults.data(forKey: Self.settingsKey),
      let settings = try? JSONDecoder().decode(TranscriptionSettings.self, from: data),
      TranscriptionModels.model(id: settings.selectedModelID)?.engine != .speakerDiarization
    else { return TranscriptionSettings() }
    return settings
  }

  public func save(_ settings: TranscriptionSettings) throws {
    guard TranscriptionModels.speech.contains(where: { $0.id == settings.selectedModelID }) else {
      throw TranscriptionError.invalidModel
    }
    defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
  }

  public func apiKeyConfigured() -> Bool {
    (try? apiKey())?.isEmpty == false
  }

  public func saveAPIKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }
    let data = Data(key.utf8)
    let query = keychainQuery()
    SecItemDelete(query as CFDictionary)
    var insertion = query
    insertion[kSecValueData as String] = data
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
      throw TranscriptionError.invalidAPIConfiguration
    }
  }

  public func clearAPIKey() {
    SecItemDelete(keychainQuery() as CFDictionary)
  }

  public func apiKey() throws -> String {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8),
      !value.isEmpty
    else { throw TranscriptionError.missingAPIKey }
    return value
  }

  private func keychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
    ]
  }
}

public struct TranscriptionModelState: Equatable, Sendable {
  public let model: TranscriptionModel
  public let isInstalled: Bool

  public init(model: TranscriptionModel, isInstalled: Bool) {
    self.model = model
    self.isInstalled = isInstalled
  }
}

public actor TranscriptionModelStore {
  private let root: URL
  private let session: URLSession
  private let fileManager: FileManager

  public init(
    storageRoot: URL,
    session: URLSession = .shared,
    fileManager: FileManager = .default
  ) {
    self.root =
      storageRoot
      .appendingPathComponent("Transcription", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
    self.session = session
    self.fileManager = fileManager
  }

  public func states() -> [TranscriptionModelState] {
    (TranscriptionModels.speech + [TranscriptionModels.speaker]).map {
      TranscriptionModelState(model: $0, isInstalled: isInstalled($0))
    }
  }

  public func isInstalled(_ model: TranscriptionModel) -> Bool {
    model.files.allSatisfy { file in
      guard
        let url = try? destination(for: model, file: file),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      else { return false }
      return values.isRegularFile == true && Int64(values.fileSize ?? -1) == file.byteCount
    }
  }

  public func modelDirectory(_ model: TranscriptionModel) throws -> URL {
    guard isInstalled(model) else { throw TranscriptionError.modelNotInstalled }
    return root.appendingPathComponent(model.id, isDirectory: true)
  }

  public func download(
    _ model: TranscriptionModel,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    guard TranscriptionModels.model(id: model.id) == model else {
      throw TranscriptionError.invalidModel
    }
    try ensureFreeSpace(model.downloadByteCount + 100 * 1_024 * 1_024)
    var completedBytes: Int64 = 0
    for file in model.files {
      try Task.checkCancellation()
      let destination = try destination(for: model, file: file)
      if isValidSize(destination, expected: file.byteCount),
        try sha256(at: destination) == file.sha256
      {
        completedBytes += file.byteCount
        progress(Double(completedBytes) / Double(model.downloadByteCount))
        continue
      }
      let request = URLRequest(url: file.url, timeoutInterval: 30 * 60)
      let (temporaryURL, response) = try await session.download(for: request)
      guard
        let response = response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode),
        response.url?.scheme?.lowercased() == "https"
      else { throw TranscriptionError.invalidDownload }
      guard isValidSize(temporaryURL, expected: file.byteCount) else {
        throw TranscriptionError.invalidDownload
      }
      guard try sha256(at: temporaryURL) == file.sha256 else {
        throw TranscriptionError.checksumMismatch
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: destination)
      }
      completedBytes += file.byteCount
      progress(Double(completedBytes) / Double(model.downloadByteCount))
    }
  }

  public func delete(_ model: TranscriptionModel) throws {
    guard TranscriptionModels.model(id: model.id) == model else {
      throw TranscriptionError.invalidModel
    }
    let directory = root.appendingPathComponent(model.id, isDirectory: true)
    guard isDescendant(directory, of: root) else { throw TranscriptionError.invalidModel }
    if fileManager.fileExists(atPath: directory.path) {
      try fileManager.removeItem(at: directory)
    }
  }

  private func destination(
    for model: TranscriptionModel,
    file: TranscriptionModelFile
  ) throws -> URL {
    let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      TranscriptionModels.model(id: model.id) == model,
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw TranscriptionError.invalidModel }
    let modelRoot = root.appendingPathComponent(model.id, isDirectory: true)
    let destination = components.reduce(modelRoot) {
      $0.appendingPathComponent(String($1), isDirectory: false)
    }
    guard isDescendant(destination, of: modelRoot) else {
      throw TranscriptionError.invalidModel
    }
    return destination
  }

  private func ensureFreeSpace(_ required: Int64) throws {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let attributes = try fileManager.attributesOfFileSystem(forPath: root.path)
    let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    guard free >= required else { throw TranscriptionError.insufficientSpace }
  }

  private func isValidSize(_ url: URL, expected: Int64) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    else { return false }
    return values.isRegularFile == true && Int64(values.fileSize ?? -1) == expected
  }

  private func sha256(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let parentPath = directory.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    return candidatePath.hasPrefix(parentPath + "/")
  }
}

public enum TranscriptAIAction: String, Codable, Hashable, Sendable {
  case summary
  case translation
}

public actor TranscriptionResultStore {
  private let root: URL
  private let fileManager: FileManager

  public init(storageRoot: URL, fileManager: FileManager = .default) {
    self.root =
      storageRoot
      .appendingPathComponent("Transcription", isDirectory: true)
      .appendingPathComponent("Episodes", isDirectory: true)
    self.fileManager = fileManager
  }

  public func save(_ transcript: GeneratedTranscript, for episodeKey: EpisodeKey) throws {
    let directory = try episodeDirectory(episodeKey)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(transcript).write(
      to: directory.appendingPathComponent("transcript.json"),
      options: .atomic
    )
  }

  public func transcript(for episodeKey: EpisodeKey) throws -> GeneratedTranscript? {
    let url = try episodeDirectory(episodeKey).appendingPathComponent("transcript.json")
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(GeneratedTranscript.self, from: Data(contentsOf: url))
  }

  public func saveAIResult(
    _ value: String,
    action: TranscriptAIAction,
    for episodeKey: EpisodeKey
  ) throws {
    let directory = try episodeDirectory(episodeKey)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(value.utf8).write(
      to: directory.appendingPathComponent("\(action.rawValue).txt"),
      options: .atomic
    )
  }

  public func aiResult(
    action: TranscriptAIAction,
    for episodeKey: EpisodeKey
  ) throws -> String? {
    let url = try episodeDirectory(episodeKey)
      .appendingPathComponent("\(action.rawValue).txt")
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func episodeDirectory(_ key: EpisodeKey) throws -> URL {
    guard key.rawValue.count == 64, key.rawValue.allSatisfy(\.isHexDigit) else {
      throw TranscriptionError.invalidTranscript
    }
    return root.appendingPathComponent(key.rawValue, isDirectory: true)
  }
}

public struct TranscriptAIClient: Sendable {
  private struct RequestBody: Encodable {
    struct Message: Encodable {
      let role: String
      let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
  }

  private struct ResponseBody: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        let content: String
      }
      let message: Message
    }
    let choices: [Choice]
  }

  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func generate(
    action: TranscriptAIAction,
    transcript: String,
    settings: TranscriptionSettings,
    apiKey: String
  ) async throws -> String {
    guard
      let baseURL = URL(string: settings.apiBaseURL),
      baseURL.scheme?.lowercased() == "https",
      baseURL.host != nil,
      !settings.apiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !apiKey.isEmpty
    else { throw TranscriptionError.invalidAPIConfiguration }
    let prompt: String
    switch action {
    case .summary:
      prompt =
        "Summarize this podcast transcript. Use concise sections and preserve important names, facts, and conclusions.\n\n\(transcript)"
    case .translation:
      prompt =
        "Translate this podcast transcript into \(settings.translationTarget). Preserve speaker labels, meaning, names, and paragraph structure. Return only the translation.\n\n\(transcript)"
    }
    var request = URLRequest(
      url: baseURL.appendingPathComponent("chat/completions"),
      timeoutInterval: 120
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(
      RequestBody(
        model: settings.apiModel,
        messages: [.init(role: "user", content: String(prompt.prefix(80_000)))],
        temperature: 0.2
      )
    )
    let (data, response) = try await session.data(for: request)
    guard
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      data.count <= 4 * 1_024 * 1_024,
      let value = try JSONDecoder().decode(ResponseBody.self, from: data).choices.first?
        .message.content.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { throw TranscriptionError.invalidAPIResponse }
    return value
  }
}
