import CoreContracts
import FeedLibrary
import Foundation
import LocalData
import QueueFeature
import SwiftUI

enum EpisodeBulkAction: Sendable {
  case markPlayed
  case markUnplayed
  case addInbox
  case removeInbox
  case favorite
  case unfavorite
  case archive
  case unarchive
  case addQueue
  case removeQueue
  case download
  case removeDownload
}

extension AppModel {
  func loadLibraryEpisodes(
    criteria: EpisodeListCriteria,
    sort: EpisodeListSort,
    feedKey: FeedKey? = nil
  ) async -> [StoredEpisode] {
    guard let store = environment.localDataStore else { return [] }
    do {
      return try await store.libraryEpisodes(
        criteria: criteria,
        sort: sort,
        feedKey: feedKey,
        limit: 1_000
      )
    } catch {
      present(error)
      return []
    }
  }

  func applyBulkAction(
    _ action: EpisodeBulkAction,
    to selectedEpisodes: [StoredEpisode]
  ) async -> Bool {
    guard !selectedEpisodes.isEmpty else { return true }
    isWorking = true
    defer { isWorking = false }
    do {
      switch action {
      case .addInbox, .removeInbox, .favorite, .unfavorite, .archive, .unarchive:
        try await applyLocalBulkAction(action, episodes: selectedEpisodes)
      case .markPlayed, .markUnplayed:
        try await applyPlaybackBulkAction(action, episodes: selectedEpisodes)
      case .addQueue:
        guard let service = environment.queueService else { return false }
        let queued = queuedEpisodeKeys
        let keys = selectedEpisodes.map(\.episodeKey).filter { !queued.contains($0) }
        _ = try await service.enqueue(keys)
      case .removeQueue:
        guard let service = environment.queueService else { return false }
        let queued = queuedEpisodeKeys
        let keys = selectedEpisodes.map(\.episodeKey).filter { queued.contains($0) }
        _ = try await service.remove(keys)
      case .download:
        guard let manager = environment.downloadManager else { return false }
        let existing = downloadByEpisodeKey
        for episode in selectedEpisodes {
          switch existing[episode.episodeKey]?.state {
          case nil, .notRequested:
            try await manager.startDownload(episode.episodeKey)
          case .failed:
            try await manager.retryDownload(episode.episodeKey)
          case .suspended:
            try await manager.resumeDownload(episode.episodeKey)
          case .queued, .running, .completed, .cancelling:
            break
          }
        }
      case .removeDownload:
        guard let manager = environment.downloadManager else { return false }
        let existing = downloadByEpisodeKey
        for episode in selectedEpisodes
        where existing[episode.episodeKey]?.state == .completed {
          try await manager.removeDownload(episode.episodeKey)
        }
      }
      _ = await environment.podcastAutomationService?.runMaintenance()
      await reloadLibrary()
      await reloadDownloads()
      return true
    } catch {
      present(error)
      await reloadLibrary()
      await reloadDownloads()
      return false
    }
  }

  func reorderQueue(_ episodeKeys: [EpisodeKey]) async -> Bool {
    guard let service = environment.queueService else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await service.reorder(episodeKeys)
      await reloadLibrary()
      return true
    } catch {
      present(error)
      await reloadLibrary()
      return false
    }
  }

  func removeQueueItems(_ episodeKeys: [EpisodeKey]) async -> Bool {
    guard let service = environment.queueService else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await service.remove(episodeKeys)
      await reloadLibrary()
      return true
    } catch {
      present(error)
      await reloadLibrary()
      return false
    }
  }

  func sortQueue(by order: QueueSortOrder) async {
    _ = await reorderQueue(QueueSorter.sortedEpisodeKeys(queue, by: order))
  }

  private func applyLocalBulkAction(
    _ action: EpisodeBulkAction,
    episodes: [StoredEpisode]
  ) async throws {
    guard let store = environment.localDataStore else { return }
    let keys = episodes.map(\.episodeKey)
    switch action {
    case .addInbox:
      try await store.setInbox(true, for: keys)
    case .removeInbox:
      try await store.setInbox(false, for: keys)
    case .favorite:
      try await store.setFavorite(true, for: keys)
    case .unfavorite:
      try await store.setFavorite(false, for: keys)
    case .archive:
      try await store.setEpisodeArchived(true, for: keys)
    case .unarchive:
      try await store.setEpisodeArchived(false, for: keys)
    default:
      break
    }
  }

  private func applyPlaybackBulkAction(
    _ action: EpisodeBulkAction,
    episodes: [StoredEpisode]
  ) async throws {
    guard
      let store = environment.localDataStore,
      let clock = environment.stateSyncClock
    else { return }
    let played = action == .markPlayed
    let timestamp = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
    let inputs = episodes.map { episode in
      PlaybackMutationInput(
        episodeKey: episode.episodeKey,
        intent: played ? .markPlayed : .markUnplayed,
        positionMilliseconds: played
          ? episode.metadata.durationMilliseconds ?? episode.positionMilliseconds : 0,
        durationMilliseconds: episode.metadata.durationMilliseconds,
        played: played
      )
    }
    _ = try await store.recordPlaybackMutations(
      inputs,
      hlc: hlc,
      createdAtMilliseconds: timestamp
    )
    await environment.stateSyncEngine?.scheduleDebounced(.playback)
  }

  func savePodcastPreferences(
    _ preferences: FeedPreferences,
    for feedKey: FeedKey
  ) async -> Bool {
    guard let store = environment.localDataStore else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      try await store.saveFeedPreferences(preferences, for: feedKey)
      await reloadLibrary()
      return true
    } catch {
      present(error)
      return false
    }
  }

  func updateFeedCredentials(
    username: String,
    password: String,
    for feedKey: FeedKey
  ) async -> Bool {
    guard let service = environment.feedLibraryService else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      let credentials = try FeedCredentials(
        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
        password: password
      )
      try await service.updateCredentials(credentials, for: feedKey)
      return true
    } catch {
      present(error)
      return false
    }
  }

  func removeFeedCredentials(for feedKey: FeedKey) async -> Bool {
    guard let service = environment.feedLibraryService else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      try await service.removeCredentials(for: feedKey)
      return true
    } catch {
      present(error)
      return false
    }
  }

  func stageDatabaseRestore(from sourceURL: URL) async {
    guard let liveDatabaseURL = environment.databaseURL else { return }
    let stagingURL = liveDatabaseURL.deletingLastPathComponent()
      .appendingPathComponent("FennecCast.restore.pending.sqlite")
    isWorking = true
    defer { isWorking = false }
    do {
      try await Task.detached(priority: .userInitiated) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
          if didAccess {
            sourceURL.stopAccessingSecurityScopedResource()
          }
        }
        try DatabaseRestoreCoordinator().stageBackup(
          at: sourceURL,
          liveDatabaseURL: liveDatabaseURL,
          stagingURL: stagingURL
        )
      }.value
      errorMessage = String(localized: "restore.staged")
    } catch {
      present(error)
    }
  }

  func loadStatistics() async -> LibraryStatistics? {
    guard let store = environment.localDataStore else { return nil }
    do {
      return try await store.libraryStatistics()
    } catch {
      present(error)
      return nil
    }
  }
}

struct PodcastSettingsView: View {
  let model: AppModel
  let feed: StoredFeed

  @Environment(\.dismiss) private var dismiss
  @State private var autoDownload = false
  @State private var autoDeletePlayed = false
  @State private var retentionEnabled = false
  @State private var retentionLimit = 10
  @State private var playbackOverrideEnabled = false
  @State private var playbackRate: Float = 1
  @State private var skipIntroSeconds = 0
  @State private var skipEndingSeconds = 0
  @State private var tags = ""
  @State private var credentialsConfigured = false
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    Form {
      Section("podcast.automation.section") {
        Toggle("podcast.autoDownload", isOn: $autoDownload)
        Toggle("podcast.autoDeletePlayed", isOn: $autoDeletePlayed)
        Toggle("podcast.retention.enabled", isOn: $retentionEnabled)
        if retentionEnabled {
          Stepper(value: $retentionLimit, in: 1...100) {
            LabeledContent("podcast.retention.limit", value: "\(retentionLimit)")
          }
        }
      }

      Section("podcast.playback.section") {
        Toggle("podcast.playback.override", isOn: $playbackOverrideEnabled)
        if playbackOverrideEnabled {
          Picker("podcast.playback.rate", selection: $playbackRate) {
            ForEach([0.75, 1, 1.25, 1.5, 2, 2.5, 3], id: \.self) { rate in
              Text("\(rate, specifier: "%g")×").tag(Float(rate))
            }
          }
        }
        Stepper(value: $skipIntroSeconds, in: 0...21_600, step: 5) {
          LabeledContent(
            "podcast.playback.skipIntro",
            value: durationLabel(seconds: skipIntroSeconds)
          )
        }
        Stepper(value: $skipEndingSeconds, in: 0...21_600, step: 5) {
          LabeledContent(
            "podcast.playback.skipEnding",
            value: durationLabel(seconds: skipEndingSeconds)
          )
        }
      }

      Section {
        TextField("podcast.tags.placeholder", text: $tags)
          .textInputAutocapitalization(.never)
      } header: {
        Text("podcast.tags.section")
      } footer: {
        Text("podcast.tags.footer")
      }

      Section {
        if credentialsConfigured {
          Label("podcast.credentials.configured", systemImage: "key.fill")
            .foregroundStyle(.secondary)
        }
        TextField("addFeed.username", text: $username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField("addFeed.password", text: $password)
        Button("podcast.credentials.save") {
          Task {
            if await model.updateFeedCredentials(
              username: username,
              password: password,
              for: feed.feedKey
            ) {
              credentialsConfigured = true
              password = ""
            }
          }
        }
        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if credentialsConfigured {
          Button("podcast.credentials.remove", role: .destructive) {
            Task {
              if await model.removeFeedCredentials(for: feed.feedKey) {
                credentialsConfigured = false
                username = ""
                password = ""
              }
            }
          }
        }
      } header: {
        Text("podcast.credentials.section")
      } footer: {
        Text("addFeed.authenticationFooter")
      }
    }
    .navigationTitle("podcast.settings.title")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("common.save") {
          Task { await savePreferences() }
        }
      }
    }
    .task { await load() }
  }

  private func load() async {
    if let preferences = model.feedPreferences[feed.feedKey] {
      autoDownload = preferences.autoDownload
      autoDeletePlayed = preferences.autoDeletePlayed
      retentionEnabled = preferences.downloadRetentionLimit != nil
      retentionLimit = preferences.downloadRetentionLimit ?? 10
      playbackOverrideEnabled = preferences.playbackRate != nil
      playbackRate = preferences.playbackRate ?? 1
      skipIntroSeconds = Int(preferences.skipIntroMilliseconds / 1_000)
      skipEndingSeconds = Int(preferences.skipEndingMilliseconds / 1_000)
      tags = preferences.tags.joined(separator: ", ")
    }
    credentialsConfigured =
      (try? await model.environment.feedLibraryService?.hasCredentials(for: feed.feedKey))
      ?? false
  }

  private func savePreferences() async {
    let parsedTags =
      tags
      .split(whereSeparator: { character in
        character == "," || character == ";" || character.isNewline
      })
      .map(String.init)
    let preferences = FeedPreferences(
      autoDownload: autoDownload,
      autoDeletePlayed: autoDeletePlayed,
      downloadRetentionLimit: retentionEnabled ? retentionLimit : nil,
      playbackRate: playbackOverrideEnabled ? playbackRate : nil,
      skipIntroMilliseconds: Int64(skipIntroSeconds) * 1_000,
      skipEndingMilliseconds: Int64(skipEndingSeconds) * 1_000,
      tags: parsedTags
    )
    if await model.savePodcastPreferences(preferences, for: feed.feedKey) {
      dismiss()
    }
  }
}

struct StatisticsView: View {
  let model: AppModel
  @State private var statistics: LibraryStatistics?

  var body: some View {
    List {
      if let statistics {
        Section("statistics.summary") {
          LabeledContent(
            "statistics.listening",
            value: durationLabel(milliseconds: statistics.listeningMilliseconds)
          )
          LabeledContent(
            "statistics.completed",
            value: "\(statistics.completedEpisodeCount)"
          )
          LabeledContent(
            "statistics.downloaded",
            value: ByteCountFormatter.string(
              fromByteCount: statistics.downloadedBytes,
              countStyle: .file
            )
          )
        }
        Section("statistics.podcasts") {
          ForEach(statistics.feeds, id: \.feedKey) { feed in
            VStack(alignment: .leading, spacing: 5) {
              Text(feed.feedTitle)
                .font(.headline)
              Text(
                String(
                  format: String(localized: "statistics.podcastDetail"),
                  durationLabel(milliseconds: feed.listeningMilliseconds),
                  Int64(feed.completedEpisodeCount),
                  ByteCountFormatter.string(
                    fromByteCount: feed.downloadedBytes,
                    countStyle: .file
                  )
                )
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
      }
    }
    .navigationTitle("statistics.title")
    .task { statistics = await model.loadStatistics() }
  }
}

struct AdvancedLibraryView: View {
  let model: AppModel
  let titleKey: LocalizedStringKey
  let feedKey: FeedKey?

  @State private var criteria: EpisodeListCriteria
  @State private var sort = EpisodeListSort.newestFirst
  @State private var episodes: [StoredEpisode] = []
  @State private var selection = Set<EpisodeKey>()
  @State private var editMode = EditMode.inactive
  @State private var isFiltering = false
  @State private var confirmsDownloadRemoval = false

  init(
    model: AppModel,
    titleKey: LocalizedStringKey = "library.title",
    feedKey: FeedKey? = nil,
    initialCriteria: EpisodeListCriteria = .all
  ) {
    self.model = model
    self.titleKey = titleKey
    self.feedKey = feedKey
    _criteria = State(initialValue: initialCriteria)
  }

  private var query: LibraryQuery {
    LibraryQuery(criteria: criteria, sort: sort, feedKey: feedKey)
  }

  private var selectedEpisodes: [StoredEpisode] {
    episodes.filter { selection.contains($0.episodeKey) }
  }

  var body: some View {
    List(selection: $selection) {
      if episodes.isEmpty {
        ContentUnavailableView("empty.episodes", systemImage: "rectangle.stack")
      } else {
        ForEach(episodes, id: \.episodeKey) { episode in
          NavigationLink {
            EpisodeDetailView(model: model, episode: episode)
          } label: {
            AdvancedEpisodeSummary(episode: episode)
          }
          .tag(episode.episodeKey)
        }
      }
    }
    .environment(\.editMode, $editMode)
    .navigationTitle(titleKey)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          isFiltering = true
        } label: {
          Label(
            "filter.title",
            systemImage: criteria.isEmpty
              ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        Menu {
          ForEach(EpisodeListSort.allCases, id: \.self) { option in
            Button {
              sort = option
            } label: {
              if option == sort {
                Label(librarySortKey(option), systemImage: "checkmark")
              } else {
                Text(librarySortKey(option))
              }
            }
          }
        } label: {
          Label("sort.title", systemImage: "arrow.up.arrow.down")
        }
        EditButton()
      }
      if editMode.isEditing {
        ToolbarItemGroup(placement: .bottomBar) {
          Button("action.selectAll") {
            selection = Set(episodes.map(\.episodeKey))
          }
          Spacer()
          Menu {
            Button("action.markPlayed") { apply(.markPlayed) }
            Button("action.markUnplayed") { apply(.markUnplayed) }
            Divider()
            Button("action.addInbox") { apply(.addInbox) }
            Button("action.removeInbox") { apply(.removeInbox) }
            Button("action.favorite") { apply(.favorite) }
            Button("action.unfavorite") { apply(.unfavorite) }
            Button("action.archive") { apply(.archive) }
            Button("action.unarchive") { apply(.unarchive) }
            Divider()
            Button("action.addQueue") { apply(.addQueue) }
            Button("action.removeQueue") { apply(.removeQueue) }
            Button("action.download") { apply(.download) }
            Button("download.remove", role: .destructive) {
              confirmsDownloadRemoval = true
            }
          } label: {
            Label("library.actions", systemImage: "ellipsis.circle")
          }
          .disabled(selection.isEmpty)
        }
      }
    }
    .sheet(isPresented: $isFiltering) {
      LibraryFilterView(criteria: $criteria)
    }
    .confirmationDialog(
      "library.removeDownloads.title",
      isPresented: $confirmsDownloadRemoval,
      titleVisibility: .visible
    ) {
      Button("download.remove", role: .destructive) { apply(.removeDownload) }
      Button("common.cancel", role: .cancel) {}
    } message: {
      Text("library.removeDownloads.message")
    }
    .task(id: query) { await reload() }
    .refreshable { await reload() }
  }

  private func apply(_ action: EpisodeBulkAction) {
    let values = selectedEpisodes
    Task {
      if await model.applyBulkAction(action, to: values) {
        selection.removeAll()
        await reload()
      }
    }
  }

  private func reload() async {
    let loaded = await model.loadLibraryEpisodes(
      criteria: criteria,
      sort: sort,
      feedKey: feedKey
    )
    guard !Task.isCancelled else { return }
    episodes = loaded
    selection.formIntersection(episodes.map(\.episodeKey))
  }
}

private struct LibraryQuery: Hashable {
  let criteria: EpisodeListCriteria
  let sort: EpisodeListSort
  let feedKey: FeedKey?
}

private struct AdvancedEpisodeSummary: View {
  let episode: StoredEpisode

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(episode.title)
        .font(.headline)
        .lineLimit(2)
      HStack(spacing: 8) {
        Text(episode.feedTitle)
          .lineLimit(1)
        if episode.played {
          Image(systemName: "checkmark.circle.fill")
        } else if episode.positionMilliseconds > 0 {
          Image(systemName: "circle.lefthalf.filled")
        }
        if episode.favorite {
          Image(systemName: "star.fill")
        }
        if episode.archived {
          Image(systemName: "archivebox.fill")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}

private struct LibraryFilterView: View {
  @Binding var criteria: EpisodeListCriteria
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("filter.localState") {
          optionalBoolPicker("filter.inbox", selection: $criteria.inbox)
          optionalBoolPicker("filter.favorites", selection: $criteria.favorite)
          optionalBoolPicker("filter.archived", selection: $criteria.archived)
        }
        Section("filter.playback") {
          Picker("filter.playback", selection: $criteria.playback) {
            Text("filter.all").tag(EpisodePlaybackFilter.any)
            Text("filter.played").tag(EpisodePlaybackFilter.played)
            Text("filter.unplayed").tag(EpisodePlaybackFilter.unplayed)
            Text("filter.inProgress").tag(EpisodePlaybackFilter.inProgress)
            Text("filter.notInProgress").tag(EpisodePlaybackFilter.notInProgress)
          }
        }
        Section("filter.availability") {
          Picker("filter.queue", selection: $criteria.queue) {
            Text("filter.all").tag(EpisodeQueueFilter.any)
            Text("filter.queued").tag(EpisodeQueueFilter.queued)
            Text("filter.notQueued").tag(EpisodeQueueFilter.notQueued)
          }
          Picker("filter.download", selection: $criteria.download) {
            Text("filter.all").tag(EpisodeDownloadFilter.any)
            Text("filter.downloaded").tag(EpisodeDownloadFilter.downloaded)
            Text("filter.notDownloaded").tag(EpisodeDownloadFilter.notDownloaded)
          }
          Picker("filter.media", selection: $criteria.media) {
            Text("filter.all").tag(EpisodeMediaFilter.any)
            Text("filter.hasMedia").tag(EpisodeMediaFilter.hasMedia)
            Text("filter.noMedia").tag(EpisodeMediaFilter.noMedia)
          }
        }
      }
      .navigationTitle("filter.title")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("filter.reset") { criteria = .all }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("common.close") { dismiss() }
        }
      }
    }
  }

  private func optionalBoolPicker(
    _ titleKey: LocalizedStringKey,
    selection: Binding<Bool?>
  ) -> some View {
    Picker(titleKey, selection: selection) {
      Text("filter.all").tag(Bool?.none)
      Text("filter.included").tag(Bool?.some(true))
      Text("filter.excluded").tag(Bool?.some(false))
    }
  }
}

private func librarySortKey(_ sort: EpisodeListSort) -> LocalizedStringKey {
  switch sort {
  case .newestFirst: "sort.newest"
  case .oldestFirst: "sort.oldest"
  case .episodeTitleAscending: "sort.episodeAZ"
  case .episodeTitleDescending: "sort.episodeZA"
  case .podcastTitleAscending: "sort.podcastAZ"
  case .podcastTitleDescending: "sort.podcastZA"
  case .durationShortestFirst: "sort.durationShortest"
  case .durationLongestFirst: "sort.durationLongest"
  }
}

private func durationLabel(seconds: Int) -> String {
  durationLabel(milliseconds: Int64(seconds) * 1_000)
}

private func durationLabel(milliseconds: Int64) -> String {
  let totalMinutes = max(0, milliseconds / 60_000)
  let hours = totalMinutes / 60
  let minutes = totalMinutes % 60
  if hours > 0 {
    return String(
      format: String(localized: "duration.hoursMinutes"),
      hours,
      minutes
    )
  }
  return String(format: String(localized: "duration.minutes"), minutes)
}
