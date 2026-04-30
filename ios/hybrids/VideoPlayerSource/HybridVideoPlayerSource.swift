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

  // Strong ref to the resource loader delegate so AVPlayer can keep
  // calling it while the asset is alive (AVFoundation only retains the
  // delegate weakly).
  private var headerLoaderDelegate: AuthHeaderAssetResourceLoader?

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

    // `AVURLAssetHTTPHeaderFieldsKey` is documented to apply only to the
    // top-level master playlist request and does NOT propagate to HLS
    // sub-resource requests (TS / fMP4 segments, key requests). When
    // headers are supplied we route every load through
    // `AuthHeaderAssetResourceLoader` instead — that delegate intercepts
    // each sub-request, restores the real https:// URL, attaches the
    // headers, and runs the request via URLSession.
    if let headers = config.headers, !headers.isEmpty {
      let prefixedURLString = url.absoluteString.replacingOccurrences(
        of: "https://", with: "\(AuthHeaderAssetResourceLoader.customScheme)://"
      )
      guard let prefixedURL = URL(string: prefixedURLString) else {
        throw SourceError.invalidUri(uri: uri).error()
      }
      let loader = AuthHeaderAssetResourceLoader(headers: headers)
      let newAsset = AVURLAsset(url: prefixedURL)
      newAsset.resourceLoader.setDelegate(loader, queue: loader.queue)
      headerLoaderDelegate = loader
      asset = newAsset
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
      _ = try? await asset.load(.duration, .preferredTransform, .isPlayable) as Any

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
    headerLoaderDelegate = nil
  }

  var memorySize: Int {
    var size = 0

    size += asset?.estimatedMemoryUsage ?? 0

    return size
  }
}
