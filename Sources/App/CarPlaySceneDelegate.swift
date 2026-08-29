import CarPlay
import CoreContracts
import Foundation
import LocalData
import UIKit

enum CarPlayContentLimit {
  static func boundedCount(requested: Int, systemMaximum: Int) -> Int {
    min(max(0, requested), max(0, systemMaximum))
  }
}

@MainActor
final class CarPlaySceneDelegate: UIResponder {
  private let environment = AppEnvironment.shared
  private var interfaceController: CPInterfaceController?
  private var tabBarTemplate: CPTabBarTemplate?
  private var continueTemplate: CPListTemplate?
  private var queueTemplate: CPListTemplate?
  private var podcastsTemplate: CPListTemplate?
  private var contentTask: Task<Void, Never>?
  private var playbackObservationTask: Task<Void, Never>?

  private func makeRootTemplates() -> [CPTemplate] {
    let continueTemplate = makeListTemplate(
      title: String(localized: "carplay.continue"),
      imageName: "play.circle.fill",
      emptyTitle: String(localized: "carplay.empty.continue")
    )
    let queueTemplate = makeListTemplate(
      title: String(localized: "carplay.queue"),
      imageName: "text.line.first.and.arrowtriangle.forward",
      emptyTitle: String(localized: "carplay.empty.queue")
    )
    let podcastsTemplate = makeListTemplate(
      title: String(localized: "carplay.podcasts"),
      imageName: "square.stack.fill",
      emptyTitle: String(localized: "carplay.empty.podcasts")
    )
    self.continueTemplate = continueTemplate
    self.queueTemplate = queueTemplate
    self.podcastsTemplate = podcastsTemplate

    let nowPlayingTemplate = CPNowPlayingTemplate.shared
    nowPlayingTemplate.tabTitle = String(localized: "carplay.nowPlaying")
    nowPlayingTemplate.tabImage = UIImage(systemName: "waveform.circle.fill")
    return [continueTemplate, queueTemplate, podcastsTemplate, nowPlayingTemplate]
  }

  private func makeListTemplate(
    title: String,
    imageName: String,
    emptyTitle: String
  ) -> CPListTemplate {
    let template = CPListTemplate(title: title, sections: [])
    template.tabTitle = title
    template.tabImage = UIImage(systemName: imageName)
    template.emptyViewTitleVariants = [emptyTitle]
    template.emptyViewSubtitleVariants = [String(localized: "carplay.empty.subtitle")]
    return template
  }

  private func observePlayback() {
    guard let playbackEngine = environment.playbackEngine else { return }
    playbackObservationTask = Task { [weak self] in
      var previousEpisodeKey: EpisodeKey?
      for await snapshot in await playbackEngine.snapshots() {
        guard !Task.isCancelled, let self else { return }
        if snapshot.item?.episodeKey != previousEpisodeKey {
          previousEpisodeKey = snapshot.item?.episodeKey
          await self.reloadContent()
        }
      }
    }
  }

  private func reloadContent() async {
    guard
      let store = environment.localDataStore,
      let continueTemplate,
      let queueTemplate,
      let podcastsTemplate
    else { return }
    do {
      async let episodes = store.libraryEpisodes(
        filter: .all,
        sort: .newestFirst,
        limit: 1_000
      )
      async let queue = store.currentQueue()
      async let feeds = store.subscribedFeeds()
      let (loadedEpisodes, loadedQueue, loadedFeeds) = try await (
        episodes,
        queue,
        feeds
      )
      guard !Task.isCancelled else { return }
      let maximumItems = CPListTemplate.maximumItemCount
      let continueItems =
        loadedEpisodes
        .filter { !$0.played && $0.positionMilliseconds > 0 }
        .prefix(maximumItems)
        .map(episodeItem)
      continueTemplate.updateSections([
        CPListSection(items: Array(continueItems))
      ])

      let queueItems = loadedQueue.prefix(maximumItems).map { queueItem in
        guard let episode = queueItem.episode else {
          let item = CPListItem(
            text: String(localized: "queue.missingEpisode"),
            detailText: nil
          )
          item.isEnabled = false
          return item
        }
        return episodeItem(episode)
      }
      queueTemplate.updateSections([
        CPListSection(items: Array(queueItems))
      ])

      let podcastItems = loadedFeeds.prefix(maximumItems).map(podcastItem)
      podcastsTemplate.updateSections([
        CPListSection(items: Array(podcastItems))
      ])
    } catch {
      showLoadFailure()
    }
  }

  private func episodeItem(_ episode: StoredEpisode) -> CPListItem {
    let item = CPListItem(text: episode.title, detailText: episode.feedTitle)
    if let duration = episode.metadata.durationMilliseconds, duration > 0 {
      item.playbackProgress = min(
        1,
        max(0, Double(episode.positionMilliseconds) / Double(duration))
      )
    }
    item.handler = { [weak self] _, completion in
      Task { @MainActor [weak self] in
        defer { completion() }
        guard let self, let playbackEngine = self.environment.playbackEngine else { return }
        do {
          try await playbackEngine.load(episode.episodeKey, autoplay: true)
          if let nowPlaying = self.tabBarTemplate?.templates.first(where: {
            $0 === CPNowPlayingTemplate.shared
          }) {
            self.tabBarTemplate?.select(nowPlaying)
          }
        } catch {
          self.showLoadFailure()
        }
      }
    }
    return item
  }

  private func podcastItem(_ feed: StoredFeed) -> CPListItem {
    let item = CPListItem(text: feed.title, detailText: feed.metadata.author)
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in
      Task { @MainActor [weak self] in
        defer { completion() }
        await self?.showPodcast(feed)
      }
    }
    return item
  }

  private func showPodcast(_ feed: StoredFeed) async {
    guard let store = environment.localDataStore, let interfaceController else { return }
    let template = CPListTemplate(title: feed.title, sections: [])
    template.emptyViewTitleVariants = [String(localized: "carplay.empty.episodes")]
    template.emptyViewSubtitleVariants = [String(localized: "carplay.empty.subtitle")]
    do {
      let maximumItems = CPListTemplate.maximumItemCount
      let episodes = try await store.libraryEpisodes(
        filter: .unplayed,
        sort: .newestFirst,
        feedKey: feed.feedKey,
        limit: min(1_000, max(1, maximumItems))
      )
      let items = episodes.prefix(maximumItems).map(episodeItem)
      template.updateSections([CPListSection(items: Array(items))])
      interfaceController.pushTemplate(template, animated: true) { _, _ in }
    } catch {
      template.emptyViewTitleVariants = [String(localized: "carplay.error.title")]
      interfaceController.pushTemplate(template, animated: true) { _, _ in }
    }
  }

  private func showLoadFailure() {
    for template in [continueTemplate, queueTemplate, podcastsTemplate].compactMap({ $0 }) {
      template.updateSections([])
      template.emptyViewTitleVariants = [String(localized: "carplay.error.title")]
      template.emptyViewSubtitleVariants = [String(localized: "carplay.error.subtitle")]
    }
  }
}

extension CarPlaySceneDelegate: CPTemplateApplicationSceneDelegate {
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    let templates = makeRootTemplates()
    let maximumTabs = CarPlayContentLimit.boundedCount(
      requested: templates.count,
      systemMaximum: CPTabBarTemplate.maximumTabCount
    )
    let tabBarTemplate = CPTabBarTemplate(
      templates: Array(templates.prefix(maximumTabs))
    )
    self.tabBarTemplate = tabBarTemplate
    interfaceController.setRootTemplate(tabBarTemplate, animated: false) { _, _ in }

    let nowPlayingTemplate = CPNowPlayingTemplate.shared
    nowPlayingTemplate.isUpNextButtonEnabled = true
    nowPlayingTemplate.upNextTitle = String(localized: "carplay.queue")
    nowPlayingTemplate.add(self)

    contentTask = Task { [weak self] in
      await self?.reloadContent()
    }
    observePlayback()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    contentTask?.cancel()
    playbackObservationTask?.cancel()
    contentTask = nil
    playbackObservationTask = nil
    CPNowPlayingTemplate.shared.remove(self)
    self.interfaceController = nil
    tabBarTemplate = nil
    continueTemplate = nil
    queueTemplate = nil
    podcastsTemplate = nil
  }
}

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
  nonisolated func nowPlayingTemplateUpNextButtonTapped(
    _ nowPlayingTemplate: CPNowPlayingTemplate
  ) {
    Task { @MainActor [weak self] in
      guard let self, let queueTemplate = self.queueTemplate else { return }
      self.tabBarTemplate?.select(queueTemplate)
    }
  }
}
