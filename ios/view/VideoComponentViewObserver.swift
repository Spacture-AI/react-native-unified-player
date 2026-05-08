//
//  VideoComponentViewObserver.swift
//  ReactNativeVideo
//
//  VLC backend rewrite — AVPlayerViewController is gone, so the observer
//  collapses into a thin delegate proxy that just forwards lifecycle hooks
//  the JS layer expects (PiP/fullscreen become inert under VLC).
//

import Foundation
import UIKit

protocol VideoComponentViewDelegate: AnyObject {
  func onPictureInPictureChange(_ isActive: Bool)
  func onFullscreenChange(_ isActive: Bool)
  func willEnterFullscreen()
  func willExitFullscreen()
  func willEnterPictureInPicture()
  func willExitPictureInPicture()
  func onReadyToDisplay()
}

final class VideoViewDelegate: NSObject, VideoComponentViewDelegate {
  weak var viewManager: HybridVideoViewViewManager?

  init(viewManager: HybridVideoViewViewManager) {
    self.viewManager = viewManager
  }

  func onPictureInPictureChange(_ isActive: Bool) {
    viewManager?.onPictureInPictureChange(isActive)
  }

  func onFullscreenChange(_ isActive: Bool) {
    viewManager?.onFullscreenChange(isActive)
  }

  func willEnterFullscreen() { viewManager?.willEnterFullscreen() }
  func willExitFullscreen() { viewManager?.willExitFullscreen() }
  func willEnterPictureInPicture() { viewManager?.willEnterPictureInPicture() }
  func willExitPictureInPicture() { viewManager?.willExitPictureInPicture() }

  func onReadyToDisplay() {
    if let player = viewManager?.player as? HybridVideoPlayer {
      player._eventEmitter?.onReadyToDisplay()
    }
  }
}
