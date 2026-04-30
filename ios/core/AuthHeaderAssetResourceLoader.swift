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
@objc public class AuthHeaderAssetResourceLoader: NSObject {
  /// Custom URL scheme used to opt AVPlayer out of native loading and
  /// route requests through this delegate. Picked to be unique enough to
  /// not collide with any RFC scheme or other delegate (`HLSSubtitleInjector`
  /// uses `rnv-hls`).
  @objc public static let customScheme = "uphls-auth"

  /// Serial queue AVFoundation will invoke our delegate methods on. Keeping
  /// it `userInitiated` matches the existing `HLSSubtitleInjector`
  /// convention and avoids stalling playback on background threads.
  @objc public let queue = DispatchQueue(
    label: "com.unifiedplayer.AuthHeaderAssetResourceLoader",
    qos: .userInitiated
  )

  private let headers: [String: String]
  private let session: URLSession

  /// AVPlayer can issue many concurrent sub-requests. Each one gets its
  /// own URLSessionDataTask; we track them by the loadingRequest so we
  /// can cancel cleanly when AVPlayer cancels (seek / asset teardown).
  private var pendingTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

  @objc public init(headers: [String: String]) {
    self.headers = headers

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 120
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: config)

    super.init()
  }

  /// Convert an `https://...` URL into `uphls-auth://...` so AVURLAsset
  /// hands every request to this delegate instead of resolving them with
  /// its built-in HTTP loader.
  @objc public static func obfuscate(_ url: URL) -> URL? {
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

extension AuthHeaderAssetResourceLoader: AVAssetResourceLoaderDelegate {
  public func resourceLoader(
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

    let task = session.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else {
        loadingRequest.finishLoading(with: error)
        return
      }
      self.queue.async {
        self.pendingTasks.removeValue(forKey: key)

        if let error = error as NSError?, error.code == NSURLErrorCancelled {
          // Request cancelled (likely AVPlayer moved on) — don't surface.
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
        // Treat any non-2xx as a failure so AVPlayer surfaces an
        // `onError` event rather than silently buffering forever.
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

          // Honor Accept-Ranges so AVPlayer knows whether seeking inside
          // a resource via byte ranges is safe.
          let acceptRanges =
            httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
          contentRequest.isByteRangeAccessSupported = acceptRanges.contains("bytes")
        }

        if let dataRequest = loadingRequest.dataRequest, let data = data {
          dataRequest.respond(with: data)
        }

        loadingRequest.finishLoading()
      }
    }

    queue.async {
      self.pendingTasks[key] = task
    }
    task.resume()
    return true
  }

  public func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let key = ObjectIdentifier(loadingRequest)
    queue.async { [weak self] in
      guard let task = self?.pendingTasks.removeValue(forKey: key) else { return }
      task.cancel()
    }
  }
}
