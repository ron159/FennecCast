import AVFoundation
import Foundation

#if os(iOS)
  import AVFAudio
#endif

public enum AVPlayerPlaybackDriverError: Error, Equatable, Sendable {
  case unsupportedURL
  case seekFailed
}

public protocol AudioSessionControlling: Sendable {
  func activatePlayback() async throws
  func deactivatePlayback() async
}

public struct SystemAudioSessionController: AudioSessionControlling {
  public init() {}

  public func activatePlayback() async throws {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    #endif
  }

  public func deactivatePlayback() async {
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    #endif
  }
}

@MainActor
public final class AVPlayerPlaybackDriver: PlaybackDriving {
  private let player: AVPlayer
  private let audioSession: any AudioSessionControlling
  private var eventHandler: (@Sendable (PlaybackDriverEvent) -> Void)?
  private var generation: UInt64 = 0
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var timeControlObservation: NSKeyValueObservation?
  #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
  #endif

  public init(
    player: AVPlayer = AVPlayer(),
    audioSession: any AudioSessionControlling = SystemAudioSessionController()
  ) {
    self.player = player
    self.audioSession = audioSession
    installObservers()
  }

  isolated deinit {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    #if os(iOS)
      if let interruptionObserver {
        NotificationCenter.default.removeObserver(interruptionObserver)
      }
      if let routeChangeObserver {
        NotificationCenter.default.removeObserver(routeChangeObserver)
      }
    #endif
    timeControlObservation?.invalidate()
  }

  public func setEventHandler(
    _ handler: @escaping @Sendable (PlaybackDriverEvent) -> Void
  ) async {
    eventHandler = handler
  }

  public func load(
    url: URL,
    positionMilliseconds: Int64,
    rate: PlaybackRate,
    generation: UInt64
  ) async throws {
    guard Self.isPlayableURL(url) else {
      throw AVPlayerPlaybackDriverError.unsupportedURL
    }
    self.generation = generation
    player.pause()
    player.defaultRate = rate.value
    let playerItem = AVPlayerItem(url: url)
    installEndObserver(for: playerItem)
    player.replaceCurrentItem(with: playerItem)
    if positionMilliseconds > 0 {
      let time = CMTime(
        seconds: Double(positionMilliseconds) / 1_000,
        preferredTimescale: 1_000
      )
      let didSeek = await player.seek(
        to: time,
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
      guard didSeek else {
        throw AVPlayerPlaybackDriverError.seekFailed
      }
    }
  }

  public func play(rate: PlaybackRate) async throws {
    try await audioSession.activatePlayback()
    player.defaultRate = rate.value
    player.play()
  }

  public func pause() async {
    player.pause()
  }

  public func seek(toMilliseconds positionMilliseconds: Int64) async throws {
    let time = CMTime(
      seconds: Double(positionMilliseconds) / 1_000,
      preferredTimescale: 1_000
    )
    let didSeek = await player.seek(
      to: time,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
    guard didSeek else {
      throw AVPlayerPlaybackDriverError.seekFailed
    }
  }

  public func setRate(_ rate: PlaybackRate) async throws {
    player.defaultRate = rate.value
    if player.timeControlStatus == .playing {
      player.rate = rate.value
    }
  }

  public func stop() async {
    player.pause()
    player.replaceCurrentItem(with: nil)
    await audioSession.deactivatePlayback()
  }

  private func installObservers() {
    // Periodic time observation is Apple's supported progress mechanism for AVPlayer.
    // Source: https://developer.apple.com/documentation/avfoundation/monitoring-playback-progress-in-your-app
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1, preferredTimescale: 10),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        self?.emitProgress(time)
      }
    }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] player, _ in
      Task { @MainActor in
        guard let self else { return }
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
          self.eventHandler?(.buffering(generation: self.generation, isBuffering: true))
        case .playing:
          self.eventHandler?(.buffering(generation: self.generation, isBuffering: false))
        case .paused:
          break
        @unknown default:
          break
        }
      }
    }
    #if os(iOS)
      installAudioSessionObservers()
    #endif
  }

  private func installEndObserver(for playerItem: AVPlayerItem) {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.eventHandler?(.ended(generation: self.generation))
      }
    }
  }

  private func emitProgress(_ time: CMTime) {
    guard time.isNumeric else { return }
    let position = max(0, Int64((time.seconds * 1_000).rounded()))
    let durationTime = player.currentItem?.duration
    let duration = durationTime.flatMap { value -> Int64? in
      guard value.isNumeric, value.seconds.isFinite else { return nil }
      return max(0, Int64((value.seconds * 1_000).rounded()))
    }
    eventHandler?(
      .progress(
        generation: generation,
        positionMilliseconds: position,
        durationMilliseconds: duration
      )
    )
  }

  private static func isPlayableURL(_ url: URL) -> Bool {
    if url.isFileURL { return true }
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }

  #if os(iOS)
    private func installAudioSessionObservers() {
      let center = NotificationCenter.default
      let session = AVAudioSession.sharedInstance()
      interruptionObserver = center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor in
          self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
        }
      }
      routeChangeObserver = center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        Task { @MainActor in
          self?.handleRouteChange(rawReason: rawReason)
        }
      }
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
      guard
        let rawType,
        let type = AVAudioSession.InterruptionType(rawValue: rawType)
      else {
        return
      }
      switch type {
      case .began:
        eventHandler?(.interruptionBegan(generation: generation))
      case .ended:
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
          .contains(.shouldResume)
        eventHandler?(
          .interruptionEnded(generation: generation, shouldResume: shouldResume)
        )
      @unknown default:
        break
      }
    }

    private func handleRouteChange(rawReason: UInt?) {
      guard
        let rawReason,
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
      else {
        return
      }
      eventHandler?(
        .routeChanged(
          generation: generation,
          shouldPause: reason == .oldDeviceUnavailable
        )
      )
    }
  #endif
}
