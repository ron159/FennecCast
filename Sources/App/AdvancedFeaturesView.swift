import CoreContracts
import FeedLibrary
import Foundation
import LocalData
import SwiftUI

extension AppModel {
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
