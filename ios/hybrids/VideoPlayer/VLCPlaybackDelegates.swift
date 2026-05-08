//
//  VLCPlaybackDelegates.swift
//  UnifiedPlayer
//
//  NSObject bridge for VLCMediaPlayerDelegate + VLCMediaDelegate. The
//  HybridVideoPlayer type cannot inherit NSObject, so we keep a dedicated
//  proxy with a weak back-reference to avoid retain cycles with VLCMedia /
//  VLCMediaPlayer.
//

import Foundation
import MobileVLCKit

protocol VLCPlaybackDelegateOwner: AnyObject {
  func vlcMediaPlayerStateDidChange()
  func vlcMediaPlayerTimeDidChange()
  func vlcMediaMetaDataDidChange(_ media: VLCMedia)
  func vlcMediaDidFinishParsing(_ media: VLCMedia)
}

/// Single delegate object hung off the player + media to satisfy VLC's
/// Obj-C delegate protocols without creating cycles (media → delegate →
/// owner is weak).
final class VLCPlaybackDelegates: NSObject, VLCMediaPlayerDelegate, VLCMediaDelegate {
  private weak var owner: VLCPlaybackDelegateOwner?

  init(owner: VLCPlaybackDelegateOwner) {
    self.owner = owner
    super.init()
  }

  func mediaPlayerStateChanged(_ aNotification: Notification) {
    dispatchToOwner { $0.vlcMediaPlayerStateDidChange() }
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    dispatchToOwner { $0.vlcMediaPlayerTimeDidChange() }
  }

  func mediaMetaDataDidChange(_ aMedia: VLCMedia) {
    dispatchToOwner { $0.vlcMediaMetaDataDidChange(aMedia) }
  }

  func mediaDidFinishParsing(_ aMedia: VLCMedia) {
    dispatchToOwner { $0.vlcMediaDidFinishParsing(aMedia) }
  }

  private func dispatchToOwner(_ work: @escaping (VLCPlaybackDelegateOwner) -> Void) {
    if Thread.isMainThread {
      if let owner { work(owner) }
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let owner = self?.owner else { return }
        work(owner)
      }
    }
  }
}
