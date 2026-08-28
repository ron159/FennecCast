import CoreContracts
import Foundation

public enum PlaybackPhase: Equatable, Sendable {
  case idle
  case preparing
  case paused
  case playing
  case buffering
  case failed
}

public struct PlaybackItem: Equatable, Sendable {
  public let episodeKey: EpisodeKey
  public let sourceURL: URL
  public let title: String
  public let podcastTitle: String
  public let durationMilliseconds: Int64?
  public let chapters: [PlaybackChapter]

  public init(
    episodeKey: EpisodeKey,
    sourceURL: URL,
    title: String,
    podcastTitle: String,
    durationMilliseconds: Int64?,
    chapters: [PlaybackChapter] = []
  ) {
    self.episodeKey = episodeKey
    self.sourceURL = sourceURL
    self.title = title
    self.podcastTitle = podcastTitle
    self.durationMilliseconds = durationMilliseconds
    self.chapters = chapters
  }
}

public struct PlaybackSnapshot: Equatable, Sendable {
  public let phase: PlaybackPhase
  public let item: PlaybackItem?
  public let positionMilliseconds: Int64
  public let durationMilliseconds: Int64?
  public let rate: PlaybackRate
  public let sleepTimerActive: Bool

  public init(
    phase: PlaybackPhase,
    item: PlaybackItem?,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64?,
    rate: PlaybackRate,
    sleepTimerActive: Bool
  ) {
    self.phase = phase
    self.item = item
    self.positionMilliseconds = positionMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.rate = rate
    self.sleepTimerActive = sleepTimerActive
  }
}
