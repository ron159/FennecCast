import AVFoundation
import AVKit
import SwiftUI

struct VideoPlayerSurface: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    return controller
  }

  func updateUIViewController(
    _ controller: AVPlayerViewController,
    context: Context
  ) {
    if controller.player !== player {
      controller.player = player
    }
  }
}
