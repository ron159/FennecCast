import CoreContracts
import DownloadsFeature
import FeedLibrary
import Foundation
import ImportExportFeature
import LocalData
import Observation
import PlaybackFeature
import QueueFeature
import StateSyncFeature
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
  let environment: AppEnvironment

  var feeds: [StoredFeed] = []
  var episodes: [StoredEpisode] = []
  var queue: [StoredQueueItem] = []
  var downloads: [LocalMediaRecord] = []
  var playback = PlaybackSnapshot(
    phase: .idle,
    item: nil,
    positionMilliseconds: 0,
    durationMilliseconds: nil,
    rate: .normal,
    sleepTimerActive: false
  )
  var sync = StateSyncSnapshot(
    phase: .idle,
    trigger: nil,
    cursor: 0,
    pendingMutationCount: 0,
    lastSuccessfulAtMilliseconds: nil,
    lastError: nil
  )
  var isWorking = false
  var errorMessage: String?
  var isPlayerPresented = false
  var syncServerURL = ""
  var syncToken = ""
  var syncTokenConfigured = false
  var transcripts: [EpisodeKey: EpisodeTranscript] = [:]
  var loadingTranscriptKeys = Set<EpisodeKey>()

  private let supplementalContentClient = SupplementalContentClient()

  init(environment: AppEnvironment) {
    self.environment = environment
  }

  var queuedEpisodeKeys: Set<EpisodeKey> {
    Set(queue.map(\.episodeKey))
  }

  var downloadByEpisodeKey: [EpisodeKey: LocalMediaRecord] {
    Dictionary(uniqueKeysWithValues: downloads.map { ($0.episodeKey, $0) })
  }

  var continueListening: [StoredEpisode] {
    episodes.filter { !$0.played && $0.positionMilliseconds > 0 }
  }

  var favorites: [StoredEpisode] {
    episodes.filter(\.favorite)
  }

  func start() async {
    loadSyncSettings()
    await reloadAll()
    _ = await environment.podcastAutomationService?.runMaintenance()
    await reloadDownloads()
    await refreshStaleFeeds()
  }

  func observePlayback() async {
    guard let engine = environment.playbackEngine else { return }
    for await snapshot in await engine.snapshots() {
      let previousEpisodeKey = playback.item?.episodeKey
      playback = snapshot
      if let previousEpisodeKey, previousEpisodeKey != snapshot.item?.episodeKey {
        _ = await environment.podcastAutomationService?.runMaintenance()
        await reloadDownloads()
      }
    }
  }

  func observeSync() async {
    guard let engine = environment.stateSyncEngine else { return }
    for await snapshot in await engine.snapshots() {
      sync = snapshot
      if snapshot.phase == .succeeded {
        await reloadLibrary()
      }
    }
  }

  func observeDownloads() async {
    while !Task.isCancelled {
      await reloadDownloads()
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
    }
  }

  func reloadAll() async {
    await reloadLibrary()
    await reloadDownloads()
    if let engine = environment.playbackEngine {
      playback = await engine.snapshot()
    }
    if let engine = environment.stateSyncEngine {
      sync = await engine.snapshot()
    }
  }

  func reloadLibrary() async {
    guard let store = environment.localDataStore else { return }
    do {
      async let loadedFeeds = store.subscribedFeeds()
      async let loadedEpisodes = store.libraryEpisodes(
        filter: .all,
        sort: .newestFirst,
        limit: 1_000
      )
      async let loadedQueue = store.currentQueue()
      feeds = try await loadedFeeds
      episodes = try await loadedEpisodes
      queue = try await loadedQueue
    } catch {
      present(error)
    }
  }

  func reloadDownloads() async {
    guard let store = environment.localDataStore else { return }
    do {
      downloads = try await store.localMediaRecords(
        states: Set(DownloadState.allCases.filter { $0 != .notRequested })
      )
    } catch {
      present(error)
    }
  }

  func addSubscription(_ value: String) async -> Bool {
    guard
      let service = environment.feedLibraryService,
      let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      errorMessage = String(localized: "error.invalidFeedURL")
      return false
    }
    return await perform {
      _ = try await service.addSubscription(from: url)
      await reloadLibrary()
    }
  }

  func refresh(_ feed: StoredFeed) async {
    guard let service = environment.feedLibraryService else { return }
    await performVoid {
      let outcome = try await service.refresh(feedKey: feed.feedKey)
      await handleAutomation(outcome, feedKey: feed.feedKey)
      await reloadLibrary()
      await reloadDownloads()
    }
  }

  func refreshAllFeeds() async {
    guard let service = environment.feedLibraryService else { return }
    isWorking = true
    defer { isWorking = false }
    var didFail = false
    for feed in feeds {
      do {
        let outcome = try await service.refresh(feedKey: feed.feedKey)
        await handleAutomation(outcome, feedKey: feed.feedKey)
      } catch {
        didFail = true
      }
    }
    await reloadLibrary()
    await reloadDownloads()
    if didFail {
      errorMessage = String(localized: "error.someFeedsFailed")
    }
  }

  func refreshStaleFeeds(
    olderThan milliseconds: Int64 = 6 * 60 * 60 * 1_000
  ) async {
    guard let service = environment.feedLibraryService else { return }
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    let staleBefore = now - milliseconds
    let staleFeeds = feeds.filter {
      guard let lastRefresh = $0.lastRefreshAtMilliseconds else { return true }
      return lastRefresh <= staleBefore
    }
    guard !staleFeeds.isEmpty else { return }
    for feed in staleFeeds {
      guard let outcome = try? await service.refresh(feedKey: feed.feedKey) else { continue }
      await handleAutomation(outcome, feedKey: feed.feedKey)
    }
    await reloadLibrary()
    await reloadDownloads()
  }

  private func handleAutomation(
    _ outcome: FeedRefreshOutcome,
    feedKey: FeedKey
  ) async {
    guard case .updated(let result) = outcome else { return }
    _ = await environment.podcastAutomationService?.handleRefresh(
      feedKey: feedKey,
      insertedEpisodeKeys: result.insertedEpisodeKeys
    )
  }

  func unsubscribe(_ feed: StoredFeed) async {
    guard let service = environment.feedLibraryService else { return }
    await performVoid {
      _ = try await service.unsubscribe(feedKey: feed.feedKey)
      await reloadLibrary()
    }
  }

  func setInbox(_ value: Bool, episode: StoredEpisode) async {
    guard let store = environment.localDataStore else { return }
    await performVoid {
      try await store.setInbox(value, for: episode.episodeKey)
      await reloadLibrary()
    }
  }

  func setFavorite(_ value: Bool, episode: StoredEpisode) async {
    guard let store = environment.localDataStore else { return }
    await performVoid {
      try await store.setFavorite(value, for: episode.episodeKey)
      await reloadLibrary()
    }
  }

  func setArchived(_ value: Bool, episode: StoredEpisode) async {
    guard let store = environment.localDataStore else { return }
    await performVoid {
      try await store.setEpisodeArchived(value, for: episode.episodeKey)
      await reloadLibrary()
    }
  }

  func setPlayed(_ value: Bool, episode: StoredEpisode) async {
    guard
      let store = environment.localDataStore,
      let clock = environment.stateSyncClock
    else { return }
    await performVoid {
      let timestamp = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
      let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
      _ = try await store.recordPlaybackMutation(
        episodeKey: episode.episodeKey,
        intent: value ? .markPlayed : .markUnplayed,
        positionMilliseconds: value
          ? episode.metadata.durationMilliseconds ?? episode.positionMilliseconds : 0,
        durationMilliseconds: episode.metadata.durationMilliseconds,
        played: value,
        hlc: hlc,
        createdAtMilliseconds: timestamp
      )
      await environment.stateSyncEngine?.scheduleDebounced(.playback)
      _ = await environment.podcastAutomationService?.runMaintenance()
      await reloadLibrary()
      await reloadDownloads()
    }
  }

  func play(_ episode: StoredEpisode) async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid {
      try await engine.load(episode.episodeKey, autoplay: true)
    }
  }

  func togglePlayback() async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid {
      try await engine.execute(.togglePlayPause)
    }
  }

  func skipForward() async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid { try await engine.skipForward() }
  }

  func skipBackward() async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid { try await engine.skipBackward() }
  }

  func skipToNext() async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid {
      try await engine.skipToNext()
      await reloadLibrary()
    }
  }

  func seek(to milliseconds: Int64) async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid { try await engine.seek(toMilliseconds: milliseconds) }
  }

  func setPlaybackRate(_ value: Float) async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid {
      try await engine.setRate(PlaybackRate(value))
    }
  }

  func setSleepTimer(minutes: Int?) async {
    guard let engine = environment.playbackEngine else { return }
    await performVoid {
      if let minutes {
        try await engine.startSleepTimer(.after(milliseconds: Int64(minutes) * 60_000))
      } else {
        await engine.cancelSleepTimer()
      }
    }
  }

  func enqueue(_ episode: StoredEpisode) async {
    guard let service = environment.queueService else { return }
    await performVoid {
      _ = try await service.enqueue(episode.episodeKey, at: .tail)
      await reloadLibrary()
    }
  }

  func removeFromQueue(_ episodeKey: EpisodeKey) async {
    guard let service = environment.queueService else { return }
    await performVoid {
      _ = try await service.remove(episodeKey)
      await reloadLibrary()
    }
  }

  func moveQueueItem(at index: Int, offset: Int) async {
    guard
      let service = environment.queueService,
      queue.indices.contains(index)
    else { return }
    let destination = index + offset
    guard queue.indices.contains(destination) else { return }
    let episodeKey = queue[index].episodeKey
    let targetKey = queue[destination].episodeKey
    await performVoid {
      let placement: QueuePlacement = offset < 0 ? .before(targetKey) : .after(targetKey)
      _ = try await service.move(episodeKey, to: placement)
      await reloadLibrary()
    }
  }

  func startDownload(_ episode: StoredEpisode) async {
    guard let manager = environment.downloadManager else { return }
    await performVoid {
      try await manager.startDownload(episode.episodeKey)
      await reloadDownloads()
    }
  }

  func applyDownloadAction(_ record: LocalMediaRecord) async {
    guard let manager = environment.downloadManager else { return }
    await performVoid {
      switch record.state {
      case .queued, .running:
        try await manager.suspendDownload(record.episodeKey)
      case .suspended:
        try await manager.resumeDownload(record.episodeKey)
      case .failed:
        try await manager.retryDownload(record.episodeKey)
      case .completed:
        try await manager.removeDownload(record.episodeKey)
      case .cancelling, .notRequested:
        break
      }
      await reloadDownloads()
    }
  }

  func cancelDownload(_ record: LocalMediaRecord) async {
    guard let manager = environment.downloadManager else { return }
    await performVoid {
      try await manager.cancelDownload(record.episodeKey)
      await reloadDownloads()
    }
  }

  func loadSyncSettings() {
    guard let settings = environment.stateSyncSettingsStore else { return }
    do {
      let configuration = try settings.load()
      syncServerURL = configuration?.serverURL.absoluteString ?? ""
      syncTokenConfigured = configuration != nil
      syncToken = ""
    } catch {
      present(error)
    }
  }

  func saveSyncSettings() async {
    guard
      let settings = environment.stateSyncSettingsStore,
      let serverURL = URL(string: syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      errorMessage = String(localized: "error.invalidSyncURL")
      return
    }
    await performVoid {
      let tokenValue: String
      if syncToken.isEmpty, let existing = try settings.load() {
        tokenValue = existing.token.rawValue
      } else {
        tokenValue = syncToken
      }
      try settings.save(serverURL: serverURL, tokenValue: tokenValue)
      syncToken = ""
      syncTokenConfigured = true
      await synchronizeManually()
    }
  }

  func clearSyncSettings() async {
    guard let settings = environment.stateSyncSettingsStore else { return }
    await performVoid {
      try settings.clear()
      await environment.stateSyncEngine?.cancelScheduledSync()
      syncServerURL = ""
      syncToken = ""
      syncTokenConfigured = false
    }
  }

  func synchronizeManually() async {
    guard let engine = environment.stateSyncEngine else { return }
    do {
      _ = try await engine.synchronize(trigger: .manual)
      await reloadLibrary()
    } catch StateSyncEngineError.notConfigured {
      errorMessage = String(localized: "error.syncNotConfigured")
    } catch {
      present(error)
    }
  }

  func importOPML(from url: URL) async {
    guard let service = environment.feedLibraryService else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let data = try await Self.readBoundedOPML(from: url)
      let subscriptions = try OPMLCodec().decode(data)
      let existingKeys = Set(feeds.map(\.feedKey))
      var importedCount = 0
      var failedCount = 0
      for subscription in subscriptions {
        guard
          let feedKey = try? FeedKey(canonicalURL: subscription.feedURL),
          !existingKeys.contains(feedKey)
        else { continue }
        do {
          _ = try await service.addSubscription(from: subscription.feedURL)
          importedCount += 1
        } catch {
          failedCount += 1
        }
      }
      await reloadLibrary()
      if failedCount > 0 {
        errorMessage = String(localized: "opml.importPartial")
      } else if importedCount == 0 {
        errorMessage = String(localized: "opml.importNoChanges")
      } else {
        errorMessage = String(localized: "opml.importSucceeded")
      }
    } catch {
      present(error)
    }
  }

  func exportOPMLDocument() -> OPMLFileDocument? {
    do {
      let subscriptions = feeds.map {
        OPMLSubscription(
          title: $0.title,
          feedURL: $0.metadata.canonicalURL
        )
      }
      return OPMLFileDocument(data: try OPMLCodec().encode(subscriptions))
    } catch OPMLCodecError.noSubscriptions {
      errorMessage = String(localized: "opml.exportEmpty")
      return nil
    } catch {
      present(error)
      return nil
    }
  }

  func exportDatabaseDocument() async -> DatabaseBackupDocument? {
    guard let store = environment.localDataStore else { return nil }
    isWorking = true
    defer { isWorking = false }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-Backup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
      let backupURL = directory.appendingPathComponent("FennecCast.sqlite")
      try await store.exportDatabase(to: backupURL)
      let values = try backupURL.resourceValues(forKeys: [.fileSizeKey])
      if let fileSize = values.fileSize,
        fileSize > DatabaseBackupDocument.defaultMaximumBytes
      {
        throw DatabaseBackupDocumentError.documentTooLarge
      }
      return try DatabaseBackupDocument(data: Data(contentsOf: backupURL))
    } catch {
      present(error)
      return nil
    }
  }

  func loadTranscript(for episode: StoredEpisode) async {
    guard
      transcripts[episode.episodeKey] == nil,
      !loadingTranscriptKeys.contains(episode.episodeKey),
      let url = episode.metadata.transcriptURL
    else { return }
    loadingTranscriptKeys.insert(episode.episodeKey)
    defer { loadingTranscriptKeys.remove(episode.episodeKey) }
    do {
      transcripts[episode.episodeKey] = try await supplementalContentClient.transcript(
        from: url,
        declaredType: episode.metadata.transcriptType
      )
    } catch {
      present(error)
    }
  }

  private func perform(_ operation: () async throws -> Void) async -> Bool {
    isWorking = true
    defer { isWorking = false }
    do {
      try await operation()
      return true
    } catch {
      present(error)
      return false
    }
  }

  private func performVoid(_ operation: () async throws -> Void) async {
    _ = await perform(operation)
  }

  private func present(_ error: any Error) {
    switch error {
    case StateSyncSettingsError.invalidServerURL,
      StateSyncSettingsError.insecureServerURL:
      errorMessage = String(localized: "error.invalidSyncURL")
    case StateSyncSettingsError.invalidToken:
      errorMessage = String(localized: "error.invalidSyncToken")
    case StateSyncEngineError.authentication:
      errorMessage = String(localized: "error.syncAuthentication")
    case StateSyncEngineError.network:
      errorMessage = String(localized: "error.network")
    default:
      errorMessage = String(localized: "error.operationFailed")
    }
  }

  private static func readBoundedOPML(from url: URL) async throws -> Data {
    try await Task.detached {
      let didAccess = url.startAccessingSecurityScopedResource()
      defer {
        if didAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else {
        throw OPMLCodecError.malformedDocument
      }
      if let fileSize = values.fileSize,
        fileSize > OPMLCodec.defaultMaximumBytes
      {
        throw OPMLCodecError.documentTooLarge
      }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      return try handle.read(upToCount: OPMLCodec.defaultMaximumBytes + 1) ?? Data()
    }.value
  }
}

struct RootView: View {
  @State private var model: AppModel

  init(environment: AppEnvironment) {
    _model = State(initialValue: AppModel(environment: environment))
  }

  var body: some View {
    if model.environment.startupFailure != nil {
      StartupFailureView()
    } else {
      TabView {
        HomeView(model: model)
          .tabItem { Label("tab.home", systemImage: "house") }
        EpisodeCollectionView(
          model: model,
          titleKey: "tab.inbox",
          episodes: model.episodes.filter(\.inbox),
          emptySystemImage: "tray"
        )
        .tabItem { Label("tab.inbox", systemImage: "tray") }
        QueueView(model: model)
          .tabItem { Label("tab.queue", systemImage: "text.line.first.and.arrowtriangle.forward") }
        SubscriptionsView(model: model)
          .tabItem { Label("tab.subscriptions", systemImage: "square.stack") }
        DownloadsView(model: model)
          .tabItem { Label("tab.downloads", systemImage: "arrow.down.circle") }
        SearchView(model: model)
          .tabItem { Label("tab.search", systemImage: "magnifyingglass") }
        SettingsView(model: model)
          .tabItem { Label("tab.settings", systemImage: "gearshape") }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if model.playback.item != nil {
          MiniPlayerView(model: model)
        }
      }
      .sheet(isPresented: $model.isPlayerPresented) {
        PlayerView(model: model)
      }
      .overlay {
        if model.isWorking {
          ProgressView()
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .task { await model.start() }
      .task { await model.observePlayback() }
      .task { await model.observeSync() }
      .task { await model.observeDownloads() }
      .alert(
        "error.title",
        isPresented: Binding(
          get: { model.errorMessage != nil },
          set: { if !$0 { model.errorMessage = nil } }
        )
      ) {
        Button("common.ok") { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
    }
  }
}

private struct StartupFailureView: View {
  var body: some View {
    ContentUnavailableView {
      Label("startup.database.title", systemImage: "externaldrive.badge.exclamationmark")
    } description: {
      Text("startup.database.message")
    }
  }
}

private struct HomeView: View {
  let model: AppModel

  var body: some View {
    NavigationStack {
      List {
        if !model.continueListening.isEmpty {
          Section("home.continue") {
            ForEach(model.continueListening.prefix(5), id: \.episodeKey) { episode in
              EpisodeRow(model: model, episode: episode)
            }
          }
        }
        Section("home.new") {
          if model.episodes.isEmpty {
            EmptyRow(titleKey: "empty.episodes")
          } else {
            ForEach(model.episodes.prefix(12), id: \.episodeKey) { episode in
              EpisodeRow(model: model, episode: episode)
            }
          }
        }
        if !model.favorites.isEmpty {
          Section("home.favorites") {
            ForEach(model.favorites.prefix(5), id: \.episodeKey) { episode in
              EpisodeRow(model: model, episode: episode)
            }
          }
        }
      }
      .navigationTitle("tab.home")
      .refreshable { await model.refreshAllFeeds() }
    }
  }
}

private struct EpisodeCollectionView: View {
  let model: AppModel
  let titleKey: LocalizedStringKey
  let episodes: [StoredEpisode]
  let emptySystemImage: String

  var body: some View {
    NavigationStack {
      List {
        if episodes.isEmpty {
          ContentUnavailableView(titleKey, systemImage: emptySystemImage)
        } else {
          ForEach(episodes, id: \.episodeKey) { episode in
            EpisodeRow(model: model, episode: episode)
          }
        }
      }
      .navigationTitle(titleKey)
      .refreshable { await model.reloadLibrary() }
    }
  }
}

private struct SubscriptionsView: View {
  let model: AppModel
  @State private var isAdding = false

  var body: some View {
    NavigationStack {
      List {
        if model.feeds.isEmpty {
          ContentUnavailableView(
            "empty.subscriptions",
            systemImage: "dot.radiowaves.left.and.right"
          )
        } else {
          ForEach(model.feeds, id: \.feedKey) { feed in
            NavigationLink {
              FeedDetailView(model: model, feed: feed)
            } label: {
              FeedRow(feed: feed)
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                Task { await model.unsubscribe(feed) }
              } label: {
                Label("action.unsubscribe", systemImage: "minus.circle")
              }
            }
          }
        }
      }
      .navigationTitle("tab.subscriptions")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            Task { await model.refreshAllFeeds() }
          } label: {
            Label("action.refreshAll", systemImage: "arrow.clockwise")
          }
          .disabled(model.feeds.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isAdding = true
          } label: {
            Label("action.addFeed", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $isAdding) {
        AddSubscriptionView(model: model, isPresented: $isAdding)
      }
      .refreshable { await model.refreshAllFeeds() }
    }
  }
}

private struct FeedDetailView: View {
  let model: AppModel
  let feed: StoredFeed
  @State private var filter = EpisodeListFilter.all
  @State private var sort = EpisodeListSort.newestFirst

  private var visibleEpisodes: [StoredEpisode] {
    var values = model.episodes.filter { $0.metadata.feedKey == feed.feedKey }
    switch filter {
    case .all:
      break
    case .inbox:
      values = values.filter(\.inbox)
    case .favorites:
      values = values.filter(\.favorite)
    case .unplayed:
      values = values.filter { !$0.played }
    case .archived:
      values = values.filter(\.archived)
    }
    if sort == .oldestFirst {
      values.reverse()
    }
    return values
  }

  var body: some View {
    List {
      Section {
        FeedRow(feed: feed)
        if let summary = feed.metadata.summaryHTML, !summary.isEmpty {
          Text(summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(6)
        }
      }
      Section {
        Picker("filter.title", selection: $filter) {
          Text("filter.all").tag(EpisodeListFilter.all)
          Text("filter.inbox").tag(EpisodeListFilter.inbox)
          Text("filter.favorites").tag(EpisodeListFilter.favorites)
          Text("filter.unplayed").tag(EpisodeListFilter.unplayed)
          Text("filter.archived").tag(EpisodeListFilter.archived)
        }
        Picker("sort.title", selection: $sort) {
          Text("sort.newest").tag(EpisodeListSort.newestFirst)
          Text("sort.oldest").tag(EpisodeListSort.oldestFirst)
        }
      }
      Section("section.episodes") {
        if visibleEpisodes.isEmpty {
          EmptyRow(titleKey: "empty.episodes")
        } else {
          ForEach(visibleEpisodes, id: \.episodeKey) { episode in
            EpisodeRow(model: model, episode: episode)
          }
        }
      }
    }
    .navigationTitle(feed.title)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.refresh(feed) }
  }
}

private struct AddSubscriptionView: View {
  let model: AppModel
  @Binding var isPresented: Bool
  @State private var url = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("addFeed.placeholder", text: $url)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
        } header: {
          Text("addFeed.section")
        } footer: {
          Text("addFeed.footer")
        }
      }
      .navigationTitle("action.addFeed")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.cancel") { isPresented = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("common.add") {
            Task {
              if await model.addSubscription(url) {
                isPresented = false
              }
            }
          }
          .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}

private struct QueueView: View {
  let model: AppModel

  var body: some View {
    NavigationStack {
      List {
        if model.queue.isEmpty {
          ContentUnavailableView(
            "empty.queue",
            systemImage: "text.line.first.and.arrowtriangle.forward"
          )
        } else {
          ForEach(Array(model.queue.enumerated()), id: \.element.episodeKey) { index, item in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(item.episode?.title ?? String(localized: "queue.missingEpisode"))
                  .font(.headline)
                Text(item.episode?.feedTitle ?? item.episodeKey.rawValue)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Menu {
                if let episode = item.episode {
                  Button {
                    Task { await model.play(episode) }
                  } label: {
                    Label("action.play", systemImage: "play.fill")
                  }
                }
                Button {
                  Task { await model.moveQueueItem(at: index, offset: -1) }
                } label: {
                  Label("action.moveUp", systemImage: "arrow.up")
                }
                .disabled(index == 0)
                Button {
                  Task { await model.moveQueueItem(at: index, offset: 1) }
                } label: {
                  Label("action.moveDown", systemImage: "arrow.down")
                }
                .disabled(index == model.queue.count - 1)
                Button(role: .destructive) {
                  Task { await model.removeFromQueue(item.episodeKey) }
                } label: {
                  Label("action.removeQueue", systemImage: "minus.circle")
                }
              } label: {
                Image(systemName: "ellipsis.circle")
              }
            }
          }
        }
      }
      .navigationTitle("tab.queue")
      .refreshable { await model.reloadLibrary() }
    }
  }
}

private struct DownloadsView: View {
  let model: AppModel

  var body: some View {
    NavigationStack {
      List {
        if model.downloads.isEmpty {
          ContentUnavailableView("empty.downloads", systemImage: "arrow.down.circle")
        } else {
          ForEach(model.downloads, id: \.episodeKey) { record in
            let episode = model.episodes.first { $0.episodeKey == record.episodeKey }
            VStack(alignment: .leading, spacing: 8) {
              Text(episode?.title ?? record.episodeKey.rawValue)
                .font(.headline)
                .lineLimit(2)
              Text(downloadStateKey(record.state))
                .font(.caption)
                .foregroundStyle(.secondary)
              if let contentLength = record.contentLength, contentLength > 0 {
                ProgressView(
                  value: Double(record.downloadedBytes),
                  total: Double(contentLength)
                )
              }
              HStack {
                Button(downloadActionKey(record.state)) {
                  Task { await model.applyDownloadAction(record) }
                }
                if record.state != .completed {
                  Button("common.cancel", role: .destructive) {
                    Task { await model.cancelDownload(record) }
                  }
                }
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
          }
        }
      }
      .navigationTitle("tab.downloads")
      .refreshable { await model.reloadDownloads() }
    }
  }
}

private struct SearchView: View {
  let model: AppModel
  @State private var query = ""
  @State private var isAdding = false

  private var results: [StoredEpisode] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return model.episodes.filter {
      $0.title.localizedCaseInsensitiveContains(trimmed)
        || $0.feedTitle.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if query.isEmpty {
          ContentUnavailableView("search.prompt", systemImage: "magnifyingglass")
        } else if results.isEmpty {
          ContentUnavailableView.search(text: query)
        } else {
          ForEach(results, id: \.episodeKey) { episode in
            EpisodeRow(model: model, episode: episode)
          }
        }
      }
      .navigationTitle("tab.search")
      .searchable(text: $query, prompt: "search.placeholder")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isAdding = true
          } label: {
            Label("action.addFeed", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $isAdding) {
        AddSubscriptionView(model: model, isPresented: $isAdding)
      }
    }
  }
}

private struct SettingsView: View {
  let model: AppModel
  @State private var isImportingOPML = false
  @State private var isExportingOPML = false
  @State private var exportDocument: OPMLFileDocument?
  @State private var isExportingDatabase = false
  @State private var databaseDocument: DatabaseBackupDocument?

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section {
          TextField("settings.sync.server", text: $model.syncServerURL)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
          SecureField("settings.sync.token", text: $model.syncToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if model.syncTokenConfigured {
            Label("settings.sync.tokenStored", systemImage: "key.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Button("settings.sync.save") {
            Task { await model.saveSyncSettings() }
          }
          Button("settings.sync.now") {
            Task { await model.synchronizeManually() }
          }
          .disabled(!model.syncTokenConfigured && model.syncToken.isEmpty)
          if model.syncTokenConfigured {
            Button("settings.sync.clear", role: .destructive) {
              Task { await model.clearSyncSettings() }
            }
          }
        } header: {
          Text("settings.sync.section")
        } footer: {
          Text("settings.sync.footer")
        }
        Section("settings.sync.status") {
          LabeledContent("settings.sync.phase", value: syncPhaseText(model.sync.phase))
          LabeledContent("settings.sync.pending", value: "\(model.sync.pendingMutationCount)")
          LabeledContent("settings.sync.cursor", value: "\(model.sync.cursor)")
          if let timestamp = model.sync.lastSuccessfulAtMilliseconds {
            LabeledContent(
              "settings.sync.lastSuccess",
              value: Date(timeIntervalSince1970: Double(timestamp) / 1_000).formatted()
            )
          }
        }
        Section("settings.about.section") {
          LabeledContent("settings.about.app", value: model.environment.appName)
          LabeledContent(
            "settings.about.protocol",
            value: "v\(model.environment.stateSyncProtocolVersion)"
          )
          Text("settings.about.localOnly")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Section {
          Button("settings.opml.import") {
            isImportingOPML = true
          }
          Button("settings.opml.export") {
            if let document = model.exportOPMLDocument() {
              exportDocument = document
              isExportingOPML = true
            }
          }
          Button("settings.backup.export") {
            Task {
              if let document = await model.exportDatabaseDocument() {
                databaseDocument = document
                isExportingDatabase = true
              }
            }
          }
        } header: {
          Text("settings.opml.section")
        } footer: {
          Text("settings.opml.footer")
        }
      }
      .navigationTitle("tab.settings")
      .fileImporter(
        isPresented: $isImportingOPML,
        allowedContentTypes: [.xml],
        allowsMultipleSelection: false
      ) { result in
        guard case .success(let urls) = result, let url = urls.first else {
          if case .failure = result {
            model.errorMessage = String(localized: "error.operationFailed")
          }
          return
        }
        Task { await model.importOPML(from: url) }
      }
      .fileExporter(
        isPresented: $isExportingOPML,
        document: exportDocument,
        contentType: .xml,
        defaultFilename: "FennecCast.opml"
      ) { result in
        if case .failure = result {
          model.errorMessage = String(localized: "error.operationFailed")
        }
        exportDocument = nil
      }
      .fileExporter(
        isPresented: $isExportingDatabase,
        document: databaseDocument,
        contentType: .fennecSQLiteDatabase,
        defaultFilename: "FennecCast-backup.sqlite"
      ) { result in
        if case .failure = result {
          model.errorMessage = String(localized: "error.operationFailed")
        }
        databaseDocument = nil
      }
    }
  }
}

struct OPMLFileDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.xml]

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard
      let data = configuration.file.regularFileContents,
      data.count <= OPMLCodec.defaultMaximumBytes
    else {
      throw OPMLCodecError.documentTooLarge
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct DatabaseBackupDocument: FileDocument {
  static let defaultMaximumBytes = 256 * 1_024 * 1_024
  static let readableContentTypes: [UTType] = [.fennecSQLiteDatabase]

  let data: Data

  init(data: Data) throws {
    guard data.count <= Self.defaultMaximumBytes else {
      throw DatabaseBackupDocumentError.documentTooLarge
    }
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard
      let data = configuration.file.regularFileContents,
      data.count <= Self.defaultMaximumBytes
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

enum DatabaseBackupDocumentError: Error {
  case documentTooLarge
}

extension UTType {
  fileprivate static let fennecSQLiteDatabase = UTType(filenameExtension: "sqlite") ?? .data
}

private struct EpisodeRow: View {
  let model: AppModel
  let episode: StoredEpisode

  private var download: LocalMediaRecord? {
    model.downloadByEpisodeKey[episode.episodeKey]
  }

  var body: some View {
    NavigationLink {
      EpisodeDetailView(model: model, episode: episode)
    } label: {
      HStack(spacing: 12) {
        Button {
          Task { await model.play(episode) }
        } label: {
          Image(systemName: episode.played ? "checkmark.circle.fill" : "play.circle.fill")
            .font(.title2)
        }
        .buttonStyle(.plain)
        VStack(alignment: .leading, spacing: 4) {
          Text(episode.title)
            .font(.headline)
            .lineLimit(2)
          HStack(spacing: 6) {
            Text(episode.feedTitle)
            if let publication = episode.metadata.publicationDateMilliseconds {
              Text("\u{2022}")
              Text(Date(timeIntervalSince1970: Double(publication) / 1_000), style: .date)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          if episode.positionMilliseconds > 0,
            let duration = episode.metadata.durationMilliseconds,
            duration > 0
          {
            ProgressView(
              value: Double(episode.positionMilliseconds),
              total: Double(duration)
            )
          }
        }
        if episode.favorite {
          Image(systemName: "star.fill")
            .foregroundStyle(.yellow)
        }
      }
    }
    .swipeActions(edge: .leading) {
      Button {
        Task { await model.setFavorite(!episode.favorite, episode: episode) }
      } label: {
        Label(
          episode.favorite ? "action.unfavorite" : "action.favorite",
          systemImage: episode.favorite ? "star.slash" : "star"
        )
      }
      .tint(.yellow)
    }
    .swipeActions(edge: .trailing) {
      if model.queuedEpisodeKeys.contains(episode.episodeKey) {
        Button(role: .destructive) {
          Task { await model.removeFromQueue(episode.episodeKey) }
        } label: {
          Label("action.removeQueue", systemImage: "minus.circle")
        }
      } else {
        Button {
          Task { await model.enqueue(episode) }
        } label: {
          Label("action.addQueue", systemImage: "text.badge.plus")
        }
        .tint(.blue)
      }
      if download == nil {
        Button {
          Task { await model.startDownload(episode) }
        } label: {
          Label("action.download", systemImage: "arrow.down.circle")
        }
        .tint(.green)
      }
    }
  }
}

private struct EpisodeDetailView: View {
  let model: AppModel
  let episode: StoredEpisode

  var body: some View {
    List {
      Section {
        Text(episode.title)
          .font(.title2.bold())
        Text(episode.feedTitle)
          .foregroundStyle(.secondary)
        if let duration = episode.metadata.durationMilliseconds {
          Label(formatDuration(duration), systemImage: "clock")
        }
      }
      Section {
        Button {
          Task { await model.play(episode) }
        } label: {
          Label("action.play", systemImage: "play.fill")
        }
        Button {
          Task {
            if model.queuedEpisodeKeys.contains(episode.episodeKey) {
              await model.removeFromQueue(episode.episodeKey)
            } else {
              await model.enqueue(episode)
            }
          }
        } label: {
          Label(
            model.queuedEpisodeKeys.contains(episode.episodeKey)
              ? "action.removeQueue" : "action.addQueue",
            systemImage: "text.badge.plus"
          )
        }
        Button {
          Task { await model.setFavorite(!episode.favorite, episode: episode) }
        } label: {
          Label(
            episode.favorite ? "action.unfavorite" : "action.favorite",
            systemImage: episode.favorite ? "star.slash" : "star"
          )
        }
        Button {
          Task { await model.setPlayed(!episode.played, episode: episode) }
        } label: {
          Label(
            episode.played ? "action.markUnplayed" : "action.markPlayed",
            systemImage: episode.played ? "circle" : "checkmark.circle"
          )
        }
        Button {
          Task { await model.setInbox(!episode.inbox, episode: episode) }
        } label: {
          Label(
            episode.inbox ? "action.removeInbox" : "action.addInbox",
            systemImage: "tray"
          )
        }
        Button {
          Task { await model.setArchived(!episode.archived, episode: episode) }
        } label: {
          Label(
            episode.archived ? "action.unarchive" : "action.archive",
            systemImage: "archivebox"
          )
        }
        if model.downloadByEpisodeKey[episode.episodeKey] == nil {
          Button {
            Task { await model.startDownload(episode) }
          } label: {
            Label("action.download", systemImage: "arrow.down.circle")
          }
        }
      }
      if let summary = episode.metadata.summaryHTML, !summary.isEmpty {
        Section("episode.description") {
          Text(summary)
            .textSelection(.enabled)
        }
      }
      if episode.metadata.transcriptURL != nil {
        Section("episode.transcript") {
          if let transcript = model.transcripts[episode.episodeKey] {
            Text(transcript.plainText)
              .textSelection(.enabled)
          } else if model.loadingTranscriptKeys.contains(episode.episodeKey) {
            ProgressView()
              .frame(maxWidth: .infinity, alignment: .center)
          } else {
            Button("episode.loadTranscript") {
              Task { await model.loadTranscript(for: episode) }
            }
          }
        }
      }
    }
    .navigationTitle("episode.title")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MiniPlayerView: View {
  let model: AppModel

  var body: some View {
    Button {
      model.isPlayerPresented = true
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "waveform.circle.fill")
          .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.playback.item?.title ?? "")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(model.playback.item?.podcastTitle ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          Task { await model.togglePlayback() }
        } label: {
          Image(systemName: isPlaying(model.playback.phase) ? "pause.fill" : "play.fill")
            .font(.title3)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
    }
    .buttonStyle(.plain)
  }
}

private struct PlayerView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var seekValue = 0.0

  var body: some View {
    NavigationStack {
      VStack(spacing: 28) {
        Spacer()
        Image(systemName: "waveform.circle.fill")
          .resizable()
          .scaledToFit()
          .frame(width: 180, height: 180)
          .foregroundStyle(.tint)
        VStack(spacing: 8) {
          Text(model.playback.item?.title ?? "")
            .font(.title2.bold())
            .multilineTextAlignment(.center)
          Text(model.playback.item?.podcastTitle ?? "")
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        VStack(spacing: 6) {
          Slider(
            value: $seekValue,
            in: 0...max(1, Double(model.playback.durationMilliseconds ?? 1)),
            onEditingChanged: { editing in
              if !editing {
                Task { await model.seek(to: Int64(seekValue.rounded())) }
              }
            }
          )
          HStack {
            Text(formatDuration(Int64(seekValue)))
            Spacer()
            Text(formatDuration(model.playback.durationMilliseconds ?? 0))
          }
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        HStack(spacing: 42) {
          Button {
            Task { await model.skipBackward() }
          } label: {
            Image(systemName: "gobackward.10")
              .font(.largeTitle)
          }
          Button {
            Task { await model.togglePlayback() }
          } label: {
            Image(
              systemName: isPlaying(model.playback.phase)
                ? "pause.circle.fill" : "play.circle.fill"
            )
            .font(.system(size: 68))
          }
          Button {
            Task { await model.skipForward() }
          } label: {
            Image(systemName: "goforward.30")
              .font(.largeTitle)
          }
        }
        HStack(spacing: 24) {
          Menu {
            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
              Button("\(rate, specifier: "%g")\u{00d7}") {
                Task { await model.setPlaybackRate(Float(rate)) }
              }
            }
          } label: {
            Label(
              "\(model.playback.rate.value, specifier: "%g")\u{00d7}",
              systemImage: "speedometer"
            )
          }
          Menu {
            Button("sleep.15") { Task { await model.setSleepTimer(minutes: 15) } }
            Button("sleep.30") { Task { await model.setSleepTimer(minutes: 30) } }
            Button("sleep.60") { Task { await model.setSleepTimer(minutes: 60) } }
            if model.playback.sleepTimerActive {
              Button("sleep.cancel", role: .destructive) {
                Task { await model.setSleepTimer(minutes: nil) }
              }
            }
          } label: {
            Label("player.sleep", systemImage: "moon.zzz")
          }
          Button {
            Task { await model.skipToNext() }
          } label: {
            Label("player.next", systemImage: "forward.end.fill")
          }
        }
        if let chapters = model.playback.item?.chapters, !chapters.isEmpty {
          List(chapters, id: \.self) { chapter in
            Button {
              Task { await model.seek(to: chapter.startMilliseconds) }
            } label: {
              HStack {
                Text(chapter.title)
                Spacer()
                Text(formatDuration(chapter.startMilliseconds))
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
              }
            }
          }
          .frame(maxHeight: 220)
        }
        Spacer()
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("common.close") { dismiss() }
        }
      }
      .onAppear {
        seekValue = Double(model.playback.positionMilliseconds)
      }
      .onChange(of: model.playback.positionMilliseconds) { _, value in
        seekValue = Double(value)
      }
    }
  }
}

private struct FeedRow: View {
  let feed: StoredFeed

  var body: some View {
    HStack(spacing: 12) {
      AsyncImage(url: feed.metadata.imageURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Image(systemName: "dot.radiowaves.left.and.right")
          .foregroundStyle(.secondary)
      }
      .frame(width: 48, height: 48)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 4) {
        Text(feed.title)
          .font(.headline)
          .lineLimit(2)
        if let author = feed.metadata.author {
          Text(author)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct EmptyRow: View {
  let titleKey: LocalizedStringKey

  var body: some View {
    Text(titleKey)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical)
  }
}

private func isPlaying(_ phase: PlaybackPhase) -> Bool {
  phase == .playing || phase == .buffering
}

private func formatDuration(_ milliseconds: Int64) -> String {
  let totalSeconds = max(0, milliseconds / 1_000)
  let hours = totalSeconds / 3_600
  let minutes = (totalSeconds % 3_600) / 60
  let seconds = totalSeconds % 60
  if hours > 0 {
    return String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
  }
  return String(format: "%lld:%02lld", minutes, seconds)
}

private func downloadStateKey(_ state: DownloadState) -> LocalizedStringKey {
  switch state {
  case .notRequested: "download.notRequested"
  case .queued: "download.queued"
  case .running: "download.running"
  case .suspended: "download.suspended"
  case .completed: "download.completed"
  case .cancelling: "download.cancelling"
  case .failed: "download.failed"
  }
}

private func downloadActionKey(_ state: DownloadState) -> LocalizedStringKey {
  switch state {
  case .queued, .running: "download.pause"
  case .suspended: "download.resume"
  case .failed: "download.retry"
  case .completed: "download.remove"
  case .cancelling, .notRequested: "common.ok"
  }
}

private func syncPhaseText(_ phase: StateSyncPhase) -> String {
  switch phase {
  case .idle: String(localized: "sync.idle")
  case .synchronizing: String(localized: "sync.synchronizing")
  case .succeeded: String(localized: "sync.succeeded")
  case .failed: String(localized: "sync.failed")
  case .notConfigured: String(localized: "sync.notConfigured")
  }
}
