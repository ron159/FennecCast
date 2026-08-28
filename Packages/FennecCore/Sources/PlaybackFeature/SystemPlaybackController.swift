#if canImport(MediaPlayer)
  import Foundation
  import MediaPlayer

  @MainActor
  public final class SystemPlaybackController {
    private let engine: PlaybackEngine
    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingCenter: MPNowPlayingInfoCenter
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var observationTask: Task<Void, Never>?

    public init(
      engine: PlaybackEngine,
      commandCenter: MPRemoteCommandCenter = .shared(),
      nowPlayingCenter: MPNowPlayingInfoCenter = .default()
    ) {
      self.engine = engine
      self.commandCenter = commandCenter
      self.nowPlayingCenter = nowPlayingCenter
      configureCommands()
      observationTask = Task { [weak self, engine] in
        let snapshots = await engine.snapshots()
        for await snapshot in snapshots {
          guard let self else { return }
          self.updateNowPlaying(snapshot)
        }
      }
    }

    isolated deinit {
      observationTask?.cancel()
      for (command, target) in commandTargets {
        command.removeTarget(target)
      }
    }

    private func configureCommands() {
      register(commandCenter.playCommand, command: .play)
      register(commandCenter.pauseCommand, command: .pause)
      register(commandCenter.togglePlayPauseCommand, command: .togglePlayPause)

      commandCenter.skipForwardCommand.preferredIntervals = [30]
      commandCenter.skipBackwardCommand.preferredIntervals = [10]
      register(
        commandCenter.skipForwardCommand,
        command: .skipForward(milliseconds: 30_000)
      )
      register(
        commandCenter.skipBackwardCommand,
        command: .skipBackward(milliseconds: 10_000)
      )

      let positionTarget = commandCenter.changePlaybackPositionCommand.addTarget {
        [weak engine] event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
          return .commandFailed
        }
        let milliseconds = max(0, Int64((event.positionTime * 1_000).rounded()))
        Task { try? await engine?.seek(toMilliseconds: milliseconds) }
        return .success
      }
      commandTargets.append((commandCenter.changePlaybackPositionCommand, positionTarget))

      commandCenter.changePlaybackRateCommand.supportedPlaybackRates = [
        0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3,
      ]
      let rateTarget = commandCenter.changePlaybackRateCommand.addTarget {
        [weak engine] event in
        guard
          let event = event as? MPChangePlaybackRateCommandEvent,
          let rate = try? PlaybackRate(event.playbackRate)
        else {
          return .commandFailed
        }
        Task { try? await engine?.setRate(rate) }
        return .success
      }
      commandTargets.append((commandCenter.changePlaybackRateCommand, rateTarget))

      let nextTarget = commandCenter.nextTrackCommand.addTarget { [weak engine] _ in
        Task { try? await engine?.skipToNext() }
        return .success
      }
      commandTargets.append((commandCenter.nextTrackCommand, nextTarget))

      register(
        commandCenter.previousTrackCommand,
        command: .seek(positionMilliseconds: 0)
      )
    }

    private func register(_ remoteCommand: MPRemoteCommand, command: PlaybackCommand) {
      remoteCommand.isEnabled = true
      let target = remoteCommand.addTarget { [weak engine] _ in
        Task { try? await engine?.execute(command) }
        return .success
      }
      commandTargets.append((remoteCommand, target))
    }

    private func updateNowPlaying(_ snapshot: PlaybackSnapshot) {
      guard let item = snapshot.item else {
        nowPlayingCenter.nowPlayingInfo = nil
        return
      }
      var info: [String: Any] = [
        MPMediaItemPropertyTitle: item.title,
        MPMediaItemPropertyAlbumTitle: item.podcastTitle,
        MPNowPlayingInfoPropertyExternalContentIdentifier: item.episodeKey.rawValue,
        MPNowPlayingInfoPropertyElapsedPlaybackTime:
          Double(snapshot.positionMilliseconds) / 1_000,
        MPNowPlayingInfoPropertyPlaybackRate:
          snapshot.phase == .playing ? snapshot.rate.value : 0,
        MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.rate.value,
        MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      ]
      if let durationMilliseconds = snapshot.durationMilliseconds {
        info[MPMediaItemPropertyPlaybackDuration] = Double(durationMilliseconds) / 1_000
      }
      nowPlayingCenter.nowPlayingInfo = info
    }
  }
#endif
