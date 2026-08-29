import Foundation
import PlaybackFeature
import SwiftUI

private enum SleepTimerUnit: Hashable {
  case minutes
  case episodes
}

struct SleepTimerView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var unit = SleepTimerUnit.minutes
  @State private var customValue = 30

  private var maximumValue: Int { unit == .minutes ? 1_440 : 100 }
  private var isCustomValueValid: Bool { (1...maximumValue).contains(customValue) }

  var body: some View {
    NavigationStack {
      Form {
        if model.playback.sleepTimerActive {
          Section("sleep.active") {
            LabeledContent(
              "sleep.remaining",
              value: sleepTimerLabel(model.playback.sleepTimer)
            )
            extensionButtons
            Button("sleep.cancel", role: .destructive) {
              Task {
                await model.setSleepTimer(mode: nil)
                dismiss()
              }
            }
          }
        }
        Section("sleep.presets") {
          HStack {
            presetButton("sleep.15", mode: .after(milliseconds: 15 * 60_000))
            presetButton("sleep.30", mode: .after(milliseconds: 30 * 60_000))
            presetButton("sleep.60", mode: .after(milliseconds: 60 * 60_000))
          }
          HStack {
            presetButton("sleep.episode1", mode: .afterEpisodes(1))
            presetButton("sleep.episode2", mode: .afterEpisodes(2))
            presetButton("sleep.episode3", mode: .afterEpisodes(3))
          }
        }
        Section {
          Picker("sleep.unit", selection: $unit) {
            Text("sleep.minutes").tag(SleepTimerUnit.minutes)
            Text("sleep.episodes").tag(SleepTimerUnit.episodes)
          }
          .pickerStyle(.segmented)
          TextField("sleep.customValue", value: $customValue, format: .number)
            .keyboardType(.numberPad)
          Button("sleep.start") {
            start(customMode)
          }
          .disabled(!isCustomValueValid)
        } header: {
          Text("sleep.custom")
        } footer: {
          Text(unit == .minutes ? "sleep.minutesLimit" : "sleep.episodesLimit")
        }
      }
      .navigationTitle("player.sleep")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }
        }
      }
      .onChange(of: unit) { _, _ in
        customValue = min(maximumValue, max(1, customValue))
      }
    }
  }

  @ViewBuilder
  private var extensionButtons: some View {
    switch model.playback.sleepTimer {
    case .timeRemaining:
      HStack {
        extendButton("sleep.extend5", value: .time(milliseconds: 5 * 60_000))
        extendButton("sleep.extend10", value: .time(milliseconds: 10 * 60_000))
        extendButton("sleep.extend30", value: .time(milliseconds: 30 * 60_000))
      }
    case .episodesRemaining:
      HStack {
        extendButton("sleep.extendEpisode1", value: .episodes(1))
        extendButton("sleep.extendEpisode2", value: .episodes(2))
        extendButton("sleep.extendEpisode3", value: .episodes(3))
      }
    case .inactive:
      EmptyView()
    }
  }

  private var customMode: PlaybackSleepMode {
    switch unit {
    case .minutes:
      .after(milliseconds: Int64(customValue) * 60_000)
    case .episodes:
      .afterEpisodes(customValue)
    }
  }

  private func presetButton(
    _ titleKey: LocalizedStringKey,
    mode: PlaybackSleepMode
  ) -> some View {
    Button(titleKey) { start(mode) }
      .buttonStyle(.bordered)
      .frame(maxWidth: .infinity)
  }

  private func extendButton(
    _ titleKey: LocalizedStringKey,
    value: PlaybackSleepExtension
  ) -> some View {
    Button(titleKey) {
      Task { await model.extendSleepTimer(value) }
    }
    .buttonStyle(.bordered)
    .frame(maxWidth: .infinity)
  }

  private func start(_ mode: PlaybackSleepMode) {
    Task {
      await model.setSleepTimer(mode: mode)
      dismiss()
    }
  }
}

func sleepTimerLabel(_ status: PlaybackSleepTimerStatus) -> String {
  switch status {
  case .inactive:
    String(localized: "player.sleep")
  case .timeRemaining(let milliseconds):
    String(
      format: String(localized: "sleep.timeRemaining"),
      formatDuration(milliseconds)
    )
  case .episodesRemaining(let count):
    String(format: String(localized: "sleep.episodesRemaining"), Int64(count))
  }
}
