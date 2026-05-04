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

  // ISO-8601 with fractional seconds — what HLS PDT lines emit.
  private static let pdtFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  /// Maximum tolerated drift between actual PDT and `previousPDT +
  /// previousEXTINF` before we treat the boundary as a discontinuity.
  /// 0.5s comfortably absorbs sub-frame rounding and float imprecision
  /// in EXTINF durations without triggering on real recording gaps,
  /// which are typically multi-second.
  private static let pdtGapToleranceSeconds: TimeInterval = 0.5

  /// Normalize an HLS media playlist for AVPlayer:
  ///   1. Reorder per-segment tags to canonical RFC 8216 order
  ///      `PDT / EXTINF / <other> / URI`. The Spacture recording proxy
  ///      emits `EXTINF / PDT / URI`. RFC 8216 §4.3.2.6 says PDT
  ///      "applies only to the next Media Segment" — AVPlayer's strict
  ///      parser interprets PDT-after-EXTINF as binding to segment[i+1],
  ///      shifting the entire timebase by one segment. Result: -12753
  ///      (timebase) → -16020 (Fig) → -15514 (HLS-FASB cannot parse),
  ///      playback dies before any segment fetch. hls.js (web) doesn't
  ///      care about tag order, which is why the same playlist plays in
  ///      the webapp.
  ///   2. Inject `#EXT-X-DISCONTINUITY` whenever a segment's PDT skews
  ///      from `previousPDT + previousEXTINF` by more than 0.5s. Defends
  ///      against unmarked recording gaps even though the current proxy
  ///      doesn't emit them.
  private func rewriteHLSPlaylist(_ data: Data) -> Data {
    guard var text = String(data: data, encoding: .utf8) else { return data }

    // Strip UTF-8 BOM if the proxy emitted one. AVPlayer's HLS parser
    // refuses to recognize the leading `#EXTM3U` if anything precedes it.
    if text.hasPrefix("\u{FEFF}") {
      text = String(text.dropFirst())
    }
    // Normalize line endings. RFC 8216 mandates LF; some upstreams emit
    // CRLF and the trailing \r leaks into our token comparisons (e.g.
    // `#EXTINF:10.030,\r` failing equality checks against expected
    // forms). Splitting on `.newlines` accepts \n / \r\n / \r and we
    // emit canonical \n on the way out.
    let lines = text.components(separatedBy: .newlines)

    var output: [String] = []
    output.reserveCapacity(lines.count + 16)

    // Last successfully-emitted segment's PDT and duration. Used to
    // detect PDT jumps that need a synthetic DISCONTINUITY.
    var lastSegmentPDT: Date? = nil
    var lastSegmentDuration: Double = 0

    // Currently-being-built segment, populated as we walk lines until the
    // URI closes the segment.
    var pendingExtinf: String? = nil
    var pendingPDTLine: String? = nil
    var pendingPDTDate: Date? = nil
    var pendingDuration: Double = 0
    var pendingOtherTags: [String] = []

    var injectedCount = 0
    var reorderedCount = 0

    for line in lines {
      if line.hasPrefix("#EXTINF:") {
        pendingExtinf = line
        let body = String(line.dropFirst("#EXTINF:".count))
        let durStr = body.components(separatedBy: ",").first ?? "0"
        pendingDuration = Double(durStr) ?? 0
      } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        pendingPDTLine = line
        let pdtStr = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
        pendingPDTDate = Self.pdtFormatter.date(from: pdtStr)
        // Track whether the proxy handed us PDT after EXTINF — purely
        // informational, drives the DEBUG counter.
        if pendingExtinf != nil { reorderedCount += 1 }
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
        // Server already declared a discontinuity here. Pass through and
        // reset our prediction baseline so we don't double-inject on the
        // next segment.
        output.append(line)
        lastSegmentPDT = nil
        lastSegmentDuration = 0
      } else if line.hasPrefix("#") || line.isEmpty {
        if pendingExtinf != nil || pendingPDTLine != nil {
          // Mid-segment tag (uncommon: BYTERANGE, KEY, etc.). Keep with
          // its segment; canonical order places these between EXTINF and
          // URI.
          pendingOtherTags.append(line)
        } else {
          // Header-level tag (#EXTM3U, #EXT-X-VERSION, …) or trailing
          // (#EXT-X-ENDLIST, blank). Pass through.
          output.append(line)
        }
      } else {
        // URI line — segment closes here.
        var needsDiscontinuity = false
        if let pdt = pendingPDTDate, let last = lastSegmentPDT {
          let expected = last.addingTimeInterval(lastSegmentDuration)
          let gap = pdt.timeIntervalSince(expected)
          if abs(gap) > Self.pdtGapToleranceSeconds {
            needsDiscontinuity = true
            injectedCount += 1
          }
        }

        if needsDiscontinuity {
          output.append("#EXT-X-DISCONTINUITY")
        }
        // Canonical RFC 8216 order.
        if let pdt = pendingPDTLine { output.append(pdt) }
        if let extinf = pendingExtinf { output.append(extinf) }
        if !pendingOtherTags.isEmpty {
          output.append(contentsOf: pendingOtherTags)
        }
        output.append(line)

        // Update prediction baseline for the next segment.
        if let pdt = pendingPDTDate {
          lastSegmentPDT = pdt
        } else if let last = lastSegmentPDT {
          lastSegmentPDT = last.addingTimeInterval(lastSegmentDuration)
        }
        lastSegmentDuration = pendingDuration

        pendingExtinf = nil
        pendingPDTLine = nil
        pendingPDTDate = nil
        pendingDuration = 0
        pendingOtherTags.removeAll(keepingCapacity: true)
      }
    }

    // Flush anything still pending (truncated playlist with no URI for
    // the last segment — defensive). Original order preserved.
    if let extinf = pendingExtinf { output.append(extinf) }
    if let pdt = pendingPDTLine { output.append(pdt) }
    if !pendingOtherTags.isEmpty {
      output.append(contentsOf: pendingOtherTags)
    }

    #if DEBUG
    if injectedCount > 0 || reorderedCount > 0 {
      print("[AuthHeaderLoader] playlist normalized: \(reorderedCount) PDT reordered, \(injectedCount) DISCONTINUITY injected")
    }
    #endif

    return output.joined(separator: "\n").data(using: .utf8) ?? data
  }

  /// Detect HLS playlist responses by URL path or response Content-Type.
  /// Both are checked because some proxies serve `.m3u8` with
  /// `application/octet-stream` and some serve playlists from non-`.m3u8`
  /// paths with the right content type.
  private func isHLSPlaylist(url: URL, response: HTTPURLResponse) -> Bool {
    if url.path.hasSuffix(".m3u8") || url.path.hasSuffix(".m3u") {
      return true
    }
    let ct = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    return ct.contains("mpegurl") || ct.contains("x-mpegurl")
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
      #if DEBUG
      print("[AuthHeaderLoader] skip non-custom-scheme url=\(url.absoluteString)")
      #endif
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
    //
    // EXCEPTION: HLS playlists. We rewrite their body in the response
    // path (DISCONTINUITY injection), which changes the byte length and
    // invalidates any byte-range AVPlayer was thinking of. Always fetch
    // the full playlist body so the rewrite is unambiguous.
    let isPlaylistPath = realURL.path.hasSuffix(".m3u8")
      || realURL.path.hasSuffix(".m3u")
    if !isPlaylistPath,
      let rangeHeader = loadingRequest.request.value(forHTTPHeaderField: "Range")
    {
      request.setValue(rangeHeader, forHTTPHeaderField: "Range")
    }

    let key = ObjectIdentifier(loadingRequest)

    #if DEBUG
    let rangeForLog = loadingRequest.request.value(forHTTPHeaderField: "Range") ?? "—"
    print("[AuthHeaderLoader] → \(realURL.absoluteString) range=\(rangeForLog)")
    #endif

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
        #if DEBUG
        print("[AuthHeaderLoader] ✗ \(realURL.absoluteString) error=\(error.localizedDescription)")
        #endif
        loadingRequest.finishLoading(with: error)
        return
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        #if DEBUG
        print("[AuthHeaderLoader] ✗ \(realURL.absoluteString) non-HTTP response")
        #endif
        self.failWithStatus(loadingRequest, -1)
        return
      }
      // Non-2xx → surface as `onError` instead of silent buffering.
      // 206 (partial content) is allowed for range requests.
      guard 200...299 ~= httpResponse.statusCode else {
        #if DEBUG
        print("[AuthHeaderLoader] ✗ HTTP \(httpResponse.statusCode) \(realURL.absoluteString)")
        #endif
        self.failWithStatus(loadingRequest, httpResponse.statusCode)
        return
      }
      // Detect HLS playlists and rewrite to inject EXT-X-DISCONTINUITY
      // at PDT jumps the upstream playlist generator omits. AVPlayer's
      // HLS-FASB parser is strict about PDT continuity; without this,
      // recording gaps surface as -15514 / -12753 and playback dies.
      let isPlaylist = self.isHLSPlaylist(url: realURL, response: httpResponse)
      let dataToServe: Data
      if isPlaylist, let raw = data {
        dataToServe = self.rewriteHLSPlaylist(raw)
      } else {
        dataToServe = data ?? Data()
      }

      #if DEBUG
      if isPlaylist {
        print("[AuthHeaderLoader] ✓ \(httpResponse.statusCode) \(realURL.absoluteString) bytes=\(data?.count ?? 0) → rewrote to \(dataToServe.count)")
      } else {
        print("[AuthHeaderLoader] ✓ \(httpResponse.statusCode) \(realURL.absoluteString) bytes=\(data?.count ?? 0)")
      }
      #endif

      if let contentRequest = loadingRequest.contentInformationRequest {
        if isPlaylist {
          // FORCE the HLS MIME type. The proxy returns
          // `application/octet-stream` for playlists, which leaves
          // AVPlayer's parser uncertain whether to treat the body as
          // HLS — depending on iOS version that uncertainty surfaces as
          // -15514 / -12753 even when the body is fine. Always declare
          // HLS here so AVPlayer commits to the HLS-FASB pipeline.
          contentRequest.contentType = "application/vnd.apple.mpegurl"
          // We're handing AVPlayer a different number of bytes than the
          // server sent. Use the rewritten size and disable byte-range
          // access so AVPlayer never tries to fetch a sub-range against
          // offsets that no longer match the upstream body.
          contentRequest.contentLength = Int64(dataToServe.count)
          contentRequest.isByteRangeAccessSupported = false
        } else {
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
      }

      if let dataRequest = loadingRequest.dataRequest {
        dataRequest.respond(with: dataToServe)
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
