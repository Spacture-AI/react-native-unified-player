import AVFoundation
import Foundation

/// `AVAssetResourceLoaderDelegate` that injects custom HTTP headers into
/// every HLS sub-request (master playlist, media playlists, TS / fMP4
/// segments, key requests).
///
/// AVPlayer's documented `AVURLAssetHTTPHeaderFieldsKey` only applies to
/// the top-level master playlist request — it does NOT propagate to
/// sub-resource requests. The standard workaround is to give AVURLAsset a
/// URL with a non-HTTPS scheme (so AVPlayer can't resolve it natively),
/// implement `AVAssetResourceLoaderDelegate`, and run every sub-request
/// through `URLSession` ourselves with the headers attached.
///
/// Activation contract:
///   • Caller rewrites `https://...` → `uphls-auth://...` before handing the
///     URL to `AVURLAsset`.
///   • Caller attaches an instance of this class as the asset's resource
///     loader delegate (and keeps a strong reference — AVFoundation only
///     holds the delegate weakly).
///   • Every loading request that arrives with our scheme is unwrapped
///     back to `https://`, executed via URLSession with the header set,
///     and streamed back to the requesting AVAssetResourceLoadingRequest.
///
/// Concurrency notes:
///   • The delegate `queue` we hand to AVFoundation is only used to call
///     INTO our `shouldWaitForLoadingOfRequestedResource` /
///     `didCancel` methods. Our completion handlers (respond + finishLoading)
///     intentionally run on URLSession's own queues so AVPlayer's parallel
///     segment fetches don't serialize on a single queue — that bottleneck
///     causes mid-playback stutter and laggy scrub.
///   • `pendingTasks` is the only mutable shared state; guarded by NSLock.
///   • `deinit` invalidates the URLSession so any in-flight tasks abort
///     immediately when the asset is released (e.g. camera switch). Without
///     this, the old player's segment fetches keep running and starve the
///     new player.
// NOTE: Intentionally `internal` (no `public`) and not `@objc`. Public
// NSObject subclasses are auto-exported into `UnifiedPlayer-Swift.h`, which
// would force a `<AVAssetResourceLoaderDelegate>` declaration. The Nitro
// C++ umbrella (`UnifiedPlayer-Swift-Cxx-Umbrella.hpp`) `#include`s that
// header from C++/ObjC++ contexts where clang modules are off, so the
// `@import AVFoundation;` line is gated out and the protocol can't resolve.
// Keeping the class module-internal removes it from the header entirely.
// Only Swift code in this module references it (HybridVideoPlayerSource);
// AVFoundation discovers the delegate methods via the Obj-C runtime.
final class AuthHeaderAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  /// Custom URL scheme used to opt AVPlayer out of native loading and
  /// route requests through this delegate.
  static let customScheme = "uphls-auth"

  /// Delegate-method dispatch queue. AVFoundation calls
  /// `shouldWaitForLoadingOfRequestedResource` and `didCancel` on this
  /// queue. Kept serial + `userInitiated`; work is offloaded to URLSession
  /// immediately so the queue never becomes the bottleneck.
  let queue = DispatchQueue(
    label: "com.unifiedplayer.AuthHeaderAssetResourceLoader",
    qos: .userInitiated
  )

  private let headers: [String: String]
  private let session: URLSession
  private let pendingLock = NSLock()
  private var pendingTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

  init(headers: [String: String]) {
    self.headers = headers

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 120
    // Disable URLCache: HLS segments are large, mostly play-once, and
    // AVFoundation has its own buffering. Caching them in URLCache
    // doubles memory pressure and trips eviction storms during seek.
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    // Default is 4 — bumping to 10 gives AVPlayer headroom to parallel-
    // fetch the first few segments after seek without queueing.
    config.httpMaximumConnectionsPerHost = 10

    self.session = URLSession(configuration: config)

    super.init()
  }

  deinit {
    // Tear down all in-flight network tasks belonging to this asset.
    // Critical when the user switches cameras: the old delegate must
    // stop fighting the new player for sockets / bandwidth.
    session.invalidateAndCancel()
  }

  /// Convert an `https://...` URL into `uphls-auth://...` so AVURLAsset
  /// hands every request to this delegate instead of resolving them with
  /// its built-in HTTP loader.
  static func obfuscate(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = customScheme
    return components.url
  }

  /// Inverse of `obfuscate`: restore the real `https://` URL the network
  /// fetch should target.
  private func deobfuscate(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = "https"
    return components.url
  }

  private func storeTask(_ task: URLSessionDataTask, for key: ObjectIdentifier) {
    pendingLock.lock()
    pendingTasks[key] = task
    pendingLock.unlock()
  }

  private func popTask(for key: ObjectIdentifier) -> URLSessionDataTask? {
    pendingLock.lock()
    let task = pendingTasks.removeValue(forKey: key)
    pendingLock.unlock()
    return task
  }

  private func failWithStatus(
    _ loadingRequest: AVAssetResourceLoadingRequest,
    _ status: Int
  ) {
    let error = NSError(
      domain: "AuthHeaderAssetResourceLoader",
      code: status,
      userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
    )
    loadingRequest.finishLoading(with: error)
  }
}

// MARK: - AVAssetResourceLoaderDelegate

extension AuthHeaderAssetResourceLoader {
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let url = loadingRequest.request.url else {
      return false
    }
    guard url.scheme == Self.customScheme else {
      // Not our scheme — let AVFoundation handle it natively (or fail).
      return false
    }
    guard let realURL = deobfuscate(url) else {
      return false
    }

    var request = URLRequest(url: realURL)
    request.httpMethod = "GET"

    // Apply caller-supplied headers (Authorization, etc.).
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }

    // Forward AVPlayer's Range header if present so partial-content
    // requests (HEAD-like probes, byte-range seeks) hit the server with
    // the same shape AVPlayer asked for.
    if let rangeHeader = loadingRequest.request.value(forHTTPHeaderField: "Range") {
      request.setValue(rangeHeader, forHTTPHeaderField: "Range")
    }

    let key = ObjectIdentifier(loadingRequest)

    // Completion handler runs on URLSession's default delegate queue
    // (concurrent), NOT on `self.queue`. AVAssetResourceLoadingRequest's
    // `respond(with:)` and `finishLoading()` are documented thread-safe,
    // so we call them directly here. This keeps parallel segment fetches
    // from serializing on the delegate queue.
    let task = session.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else {
        loadingRequest.finishLoading(with: error)
        return
      }
      _ = self.popTask(for: key)

      if let error = error as NSError?, error.code == NSURLErrorCancelled {
        // Request cancelled (likely AVPlayer moved on or asset released).
        return
      }
      if let error = error {
        loadingRequest.finishLoading(with: error)
        return
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        self.failWithStatus(loadingRequest, -1)
        return
      }
      // Non-2xx → surface as `onError` instead of silent buffering.
      // 206 (partial content) is allowed for range requests.
      guard 200...299 ~= httpResponse.statusCode else {
        self.failWithStatus(loadingRequest, httpResponse.statusCode)
        return
      }

      if let contentRequest = loadingRequest.contentInformationRequest {
        contentRequest.contentType =
          httpResponse.value(forHTTPHeaderField: "Content-Type")
          ?? "application/octet-stream"

        // Prefer Content-Range's total-length when the server returned
        // a 206; otherwise use Content-Length / expectedContentLength.
        if let contentRangeHeader = httpResponse.value(forHTTPHeaderField: "Content-Range"),
          let totalSlice = contentRangeHeader.split(separator: "/").last,
          let totalLength = Int64(totalSlice)
        {
          contentRequest.contentLength = totalLength
        } else if httpResponse.expectedContentLength > 0 {
          contentRequest.contentLength = httpResponse.expectedContentLength
        } else if let data = data {
          contentRequest.contentLength = Int64(data.count)
        }

        let acceptRanges =
          httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
        contentRequest.isByteRangeAccessSupported = acceptRanges.contains("bytes")
      }

      if let dataRequest = loadingRequest.dataRequest, let data = data {
        dataRequest.respond(with: data)
      }

      loadingRequest.finishLoading()
    }

    storeTask(task, for: key)
    task.resume()
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let key = ObjectIdentifier(loadingRequest)
    if let task = popTask(for: key) {
      task.cancel()
    }
  }
}
