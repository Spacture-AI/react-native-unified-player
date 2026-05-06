//
//  HybridVideoPlayerSource.swift
//  ReactNativeVideo
//
//  Created by Krzysztof Moch on 23/09/2024.
//

import AVFoundation
import Foundation
import NitroModules

class HybridVideoPlayerSource: HybridVideoPlayerSourceSpec, NativeVideoPlayerSourceSpec {
  var asset: AVURLAsset?
  var uri: String
  var config: NativeVideoConfig

  var drmManager: DRMManagerSpec?

  let url: URL
  private let sourceLoader = SourceLoader()

  init(config: NativeVideoConfig) throws {
    self.uri = config.uri
    self.config = config

    guard let url = URL(string: uri) else {
      throw SourceError.invalidUri(uri: uri).error()
    }

    self.url = url

    super.init()

    if config.drm != nil {
      // Try to get the DRM manager
      // If no DRM manager is found, it will throw an error
      _ = try PluginsRegistry.shared.getDrmManager(source: self)
    }
  }

  deinit {
    releaseAsset()
  }

  func getAssetInformationAsync() -> Promise<VideoInformation> {
    let promise = Promise<VideoInformation>()

    Task.detached(priority: .utility) { [weak self] in
      guard let self else {
        promise.reject(
          withError: LibraryError.deallocated(objectName: "HybridVideoPlayerSource").error())
        return
      }

      do {
        let videoInformation = try await self.sourceLoader.load(priority: .utility) {
          if self.url.isFileURL {
            try VideoFileHelper.validateReadPermission(for: self.url)
          }

          try await self.initializeAsset()

          guard let asset = self.asset else {
            throw PlayerError.assetNotInitialized.error()
          }

          return try await asset.getAssetInformation()
        }

        promise.resolve(withResult: videoInformation)
      } catch {
        if error is CancellationError {
          promise.reject(withError: SourceError.cancelled.error())
        } else {
          promise.reject(withError: error)
        }
      }
    }

    return promise
  }

  func initializeAsset() async throws {
    guard asset == nil else {
      return
    }

    // Pass headers via `AVURLAssetHTTPHeaderFieldsKey` — the v1.0.18
    // path that's been working in production. The documented caveat is
    // that this key only applies to the master playlist request, not
    // sub-resource fetches (segments / keys). The Spacture proxy doesn't
    // require bearer auth on segment endpoints (`/recordings/...`), so
    // master-playlist auth is sufficient.
    //
    // The v1.0.19+ `AuthHeaderAssetResourceLoader` route was added to
    // propagate headers to every sub-request via a custom URL scheme —
    // but iOS 17's HLS-FASB / FigPlayerInterstitial pipeline doesn't
    // trust data delivered through a custom-scheme resource loader and
    // bails with -15514 / -12753 / -15671 before any segment fetch.
    // hls.js (web) doesn't share this strictness, which is why the same
    // playlist plays in the webapp. If a future deployment ever needs
    // segment auth, prefer a localhost reverse-proxy approach over the
    // resource-loader trick — AVPlayer's native HLS pipeline is not
    // forgiving about being intercepted at the URL-loader layer.
    if let headers = config.headers, !headers.isEmpty {
      let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
      asset = AVURLAsset(url: url, options: options)
    } else {
      asset = AVURLAsset(url: url)
    }

    guard let asset else {
      throw SourceError.failedToInitializeAsset.error()
    }

    do {
      if let drmParams = config.drm {
        drmManager = try PluginsRegistry.shared.getDrmManager(source: self)

        guard let drmManager else {
          throw LibraryError.DRMPluginNotFound.error()
        }

        do {
          try drmManager.createContentKeyRequest(for: asset, drmParams: drmParams)
        } catch {
          print("[UnifiedPlayer] Failed to create content key request for DRM: \(drmParams)")
        }
      }

      // Code browned from expo-video https://github.com/expo/expo/blob/ea17c9b1ce5111e1454b089ba381f3feb93f33cc/packages/expo-video/ios/VideoPlayerItem.swift#L40C30-L40C73
      // If we don't load those properties, they will be loaded on main thread causing lags
      //
      // `.tracks` is required for HEVC HLS: AVAssetTrack.formatDescriptions carries the
      // HEVC `hvcC` atom (VPS/SPS/PPS). If the AVPlayer attaches to the display layer
      // before format descriptions resolve, the HEVC decoder spins up without parameter
      // sets and renders black frames while audio plays normally. Loading async here
      // forces format discovery off the main thread and before first paint.
      _ = try? await asset.load(.duration, .preferredTransform, .isPlayable, .tracks) as Any

      try Task.checkCancellation()
    } catch {
      self.asset = nil
      if error is CancellationError {
        throw SourceError.cancelled.error()
      }
      throw error
    }
  }

  func getAsset() async throws -> AVURLAsset {
    if let asset {
      return asset
    }

    do {
      try await sourceLoader.load {
        try await self.initializeAsset()
      }

      guard let asset else {
        throw SourceError.failedToInitializeAsset.error()
      }

      return asset
    } catch {
      if error is CancellationError {
        self.asset = nil
        throw SourceError.cancelled.error()
      }
      throw error
    }
  }

  func releaseAsset() {
    sourceLoader.cancelSync()
    asset = nil
  }

  var memorySize: Int {
    var size = 0

    size += asset?.estimatedMemoryUsage ?? 0

    return size
  }
}
