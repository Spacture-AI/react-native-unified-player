//
//  HybridVideoPlayerSource.swift
//  ReactNativeVideo
//
//  Created by Krzysztof Moch on 23/09/2024.
//

import Foundation
import NitroModules

class HybridVideoPlayerSource: HybridVideoPlayerSourceSpec {
  var uri: String
  var config: NativeVideoConfig

  let url: URL

  init(config: NativeVideoConfig) throws {
    self.uri = config.uri
    self.config = config

    guard let url = URL(string: uri) else {
      throw SourceError.invalidUri(uri: uri).error()
    }

    self.url = url

    super.init()
  }

  func getAssetInformationAsync() -> Promise<VideoInformation> {
    let promise = Promise<VideoInformation>()
    // VLC does not expose pre-load asset metadata cheaply; surface defaults
    // so the JS API contract still resolves. Real values land via onLoad.
    promise.resolve(
      withResult: VideoInformation(
        bitrate: 0,
        width: 0,
        height: 0,
        duration: 0,
        fileSize: 0,
        isHDR: false,
        isLive: false,
        orientation: .unknown
      )
    )
    return promise
  }

  func releaseAsset() {
    // No persistent asset to release with VLC; lifecycle is owned by the
    // VLCMedia attached to VLCMediaPlayer in HybridVideoPlayer.
  }

  var memorySize: Int { 0 }
}
