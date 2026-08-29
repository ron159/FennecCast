import CoreContracts
import Foundation
import PlaybackFeature
import Testing

struct PlaybackPolicyTests {
  @Test
  func rateValidatesFiniteSupportedRange() throws {
    #expect(try PlaybackRate(1).value == 1)
    #expect(try PlaybackRate(0.5).value == 0.5)
    #expect(try PlaybackRate(3).value == 3)
    #expect(throws: PlaybackPolicyError.invalidRate) { try PlaybackRate(0.49) }
    #expect(throws: PlaybackPolicyError.invalidRate) { try PlaybackRate(3.01) }
    #expect(throws: PlaybackPolicyError.invalidRate) { try PlaybackRate(.infinity) }
  }

  @Test
  func completionMatchesAntennaPodThirtySecondDefault() throws {
    let policy = PlaybackCompletionPolicy()

    #expect(
      try policy.shouldMarkPlayed(positionMilliseconds: 70_000, durationMilliseconds: 100_000))
    #expect(
      try policy.shouldMarkPlayed(positionMilliseconds: 69_999, durationMilliseconds: 100_000)
        == false)
    #expect(
      try policy.shouldMarkPlayed(
        positionMilliseconds: 1_000,
        durationMilliseconds: nil,
        ended: true
      ))
    #expect(throws: PlaybackPolicyError.invalidTime) {
      try policy.shouldMarkPlayed(positionMilliseconds: -1, durationMilliseconds: 100)
    }
  }

  @Test
  func sleepTimerUsesMonotonicDeadlineAndEpisodeCount() throws {
    var timer = PlaybackSleepTimer()
    try timer.start(.after(milliseconds: 60_000), monotonicNowMilliseconds: 1_000)
    #expect(timer.shouldPause(monotonicNowMilliseconds: 60_999) == false)
    let reachedDeadline = timer.shouldPause(monotonicNowMilliseconds: 61_000)
    #expect(reachedDeadline)
    #expect(timer.isActive == false)

    try timer.start(.afterEpisodes(2), monotonicNowMilliseconds: 70_000)
    #expect(timer.episodeDidEnd() == false)
    let reachedEpisodeCount = timer.episodeDidEnd()
    #expect(reachedEpisodeCount)
    #expect(timer.isActive == false)
    #expect(throws: PlaybackPolicyError.invalidSleepTimer) {
      try timer.start(.afterEpisodes(0), monotonicNowMilliseconds: 0)
    }
  }

  @Test
  func sleepTimerReportsRemainingAndExtendsMatchingTarget() throws {
    var timer = PlaybackSleepTimer()
    try timer.start(.after(milliseconds: 60_000), monotonicNowMilliseconds: 1_000)

    #expect(
      timer.status(monotonicNowMilliseconds: 11_000)
        == .timeRemaining(milliseconds: 50_000)
    )
    try timer.extend(.time(milliseconds: 10_000))
    #expect(
      timer.status(monotonicNowMilliseconds: 11_000)
        == .timeRemaining(milliseconds: 60_000)
    )
    #expect(throws: PlaybackPolicyError.invalidSleepTimer) {
      try timer.extend(.episodes(1))
    }

    try timer.start(.afterEpisodes(2), monotonicNowMilliseconds: 20_000)
    #expect(timer.status(monotonicNowMilliseconds: 20_000) == .episodesRemaining(2))
    try timer.extend(.episodes(3))
    #expect(timer.status(monotonicNowMilliseconds: 20_000) == .episodesRemaining(5))
    #expect(throws: PlaybackPolicyError.invalidSleepTimer) {
      try timer.extend(.time(milliseconds: 1_000))
    }
  }

  @Test
  func chaptersNormalizeOrderAndPreferHigherPrioritySource() throws {
    let feed = try PlaybackChapter(
      startMilliseconds: 0,
      title: "  Feed Intro  ",
      source: .feed
    )
    let embedded = try PlaybackChapter(
      startMilliseconds: 0,
      title: "Embedded Intro",
      source: .embedded
    )
    let later = try PlaybackChapter(
      startMilliseconds: 30_000,
      title: "Topic",
      source: .podcastIndex
    )
    let samePriorityTie = try PlaybackChapter(
      startMilliseconds: 30_000,
      title: "A Topic",
      source: .podcastIndex
    )

    #expect(
      ChapterMerger.merge([later, feed, embedded, samePriorityTie]) == [
        embedded, samePriorityTie,
      ])
    #expect(throws: PlaybackPolicyError.invalidChapter) {
      try PlaybackChapter(startMilliseconds: -1, title: "Bad", source: .feed)
    }
    #expect(throws: PlaybackPolicyError.invalidChapter) {
      try PlaybackChapter(startMilliseconds: 0, title: "  ", source: .feed)
    }
  }
}
