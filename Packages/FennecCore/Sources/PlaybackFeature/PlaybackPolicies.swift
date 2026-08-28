import Foundation

public enum PlaybackPolicyError: Error, Equatable, Sendable {
  case invalidRate
  case invalidTime
  case invalidSleepTimer
  case invalidChapter
}

public struct PlaybackRate: Codable, Equatable, Hashable, Sendable {
  public let value: Float

  public init(_ value: Float) throws {
    guard value.isFinite, (0.5...3).contains(value) else {
      throw PlaybackPolicyError.invalidRate
    }
    self.value = value
  }
}

public struct PlaybackCompletionPolicy: Equatable, Sendable {
  public static let defaultRemainingThresholdMilliseconds: Int64 = 30_000

  public init() {}

  public func shouldMarkPlayed(
    positionMilliseconds: Int64,
    durationMilliseconds: Int64?,
    ended: Bool = false
  ) throws -> Bool {
    guard positionMilliseconds >= 0 else {
      throw PlaybackPolicyError.invalidTime
    }
    if let durationMilliseconds, durationMilliseconds < 0 {
      throw PlaybackPolicyError.invalidTime
    }
    if ended {
      return true
    }
    guard let durationMilliseconds, durationMilliseconds > 0 else {
      return false
    }
    return positionMilliseconds
      >= durationMilliseconds - Self.defaultRemainingThresholdMilliseconds
  }
}

public enum PlaybackSleepMode: Equatable, Sendable {
  case after(milliseconds: Int64)
  case afterEpisodes(Int)
}

public struct PlaybackSleepTimer: Equatable, Sendable {
  private enum Target: Equatable, Sendable {
    case deadline(Int64)
    case episodes(Int)
  }

  private var target: Target?

  public init() {}

  public var isActive: Bool { target != nil }

  public mutating func start(
    _ mode: PlaybackSleepMode,
    monotonicNowMilliseconds: Int64
  ) throws {
    guard monotonicNowMilliseconds >= 0 else {
      throw PlaybackPolicyError.invalidSleepTimer
    }
    switch mode {
    case .after(let milliseconds):
      guard milliseconds > 0 else {
        throw PlaybackPolicyError.invalidSleepTimer
      }
      let (deadline, overflow) = monotonicNowMilliseconds.addingReportingOverflow(milliseconds)
      guard !overflow else {
        throw PlaybackPolicyError.invalidSleepTimer
      }
      target = .deadline(deadline)
    case .afterEpisodes(let count):
      guard count > 0 else {
        throw PlaybackPolicyError.invalidSleepTimer
      }
      target = .episodes(count)
    }
  }

  public mutating func cancel() {
    target = nil
  }

  public mutating func shouldPause(monotonicNowMilliseconds: Int64) -> Bool {
    guard case .deadline(let deadline) = target,
      monotonicNowMilliseconds >= deadline
    else {
      return false
    }
    target = nil
    return true
  }

  public mutating func episodeDidEnd() -> Bool {
    guard case .episodes(let remaining) = target else {
      return false
    }
    if remaining == 1 {
      target = nil
      return true
    }
    target = .episodes(remaining - 1)
    return false
  }
}
