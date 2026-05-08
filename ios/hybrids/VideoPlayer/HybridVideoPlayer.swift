//
//  HybridVideoPlayer.swift
//  ReactNativeVideo
//
//  Created by Krzysztof Moch on 09/10/2024.
//  MobileVLCKit backend for HLS (MediaMTX-style manifests, relative .ts
//  segments resolved by VLC against the playlist URL).
//

import Foundation
import MobileVLCKit
import NitroModules

// MARK: - HLS / network tuning (conservative defaults; override via source headers if needed)

private enum VLCHLSDefaults {
  /// Milliseconds of media to prefetch before playback resumes.
  /// VLC sits buffering for at least this long after every seek, so we
  /// keep it small for VOD HLS (recordings) where the user expects scrub
  /// to land near-instantly. Bump back up if you see frequent stutter.
  static let networkCachingMs = 300
  /// Same as above but only used when libvlc tags the stream as live; our
  /// MediaMTX recordings are VOD, so this almost never applies. Keep it
  /// low so the rare live tail doesn't add seconds of pre-roll.
  static let liveCachingMs = 300
}

final class HybridVideoPlayer: HybridVideoPlayerSpec, VLCPlaybackDelegateOwner {

  public let mediaPlayer: VLCMediaPlayer
  private var media: VLCMedia?
  private var vlcDelegates: VLCPlaybackDelegates?

  /// Local 127.0.0.1 HTTP proxy used to inject Authorization on HLS
  /// manifest + segment fetches. libvlc 3.x ignores `--http-header(s)`,
  /// so we point VLC at this proxy when the JS layer passes an
  /// Authorization header. nil when the source is unauthenticated.
  private var authProxy: HLSAuthProxy?

  private var lastReportedRate: Double = 1.0
  private var hasFiredOnLoad: Bool = false
  private var hasFiredOnLoadStart: Bool = false
  private var lastEmittedIsPlaying: Bool = false
  private var lastEmittedIsBuffering: Bool = false
  private var pendingSeekSeconds: Double? = nil
  private var hasEmittedEndForCurrentItem: Bool = false

  /// Monotonic playback time from VLC; used by the stall watchdog.
  private var lastProgressTimeSeconds: Double = 0
  private var lastProgressTickMonotonic: TimeInterval = 0

  private var stallCheckTimer: Timer?
  private var reconnectAttempts: Int = 0
  private static let maxAutoReconnects = 3
  private static let stallNoProgressSeconds: TimeInterval = 4.0
  private static let stallCheckIntervalSeconds: TimeInterval = 1.0

  /// JS called `play()` before a `UIView` drawable existed — iOS VLC often
  /// needs the drawable before demux/decode can finish; we re-issue `play()`
  /// from `VideoComponentView` when the surface attaches.
  private var wantsPlaybackWhenDrawableReady: Bool = false

  /// Marshal a closure onto the main thread, executing inline if we're
  /// already there. VLC's renderer (`VLCOpenGLES2VideoView`) reaches into
  /// `CAEAGLLayer` to manage its OpenGL renderbuffer when the active
  /// media changes (`mediaPlayer.media = ...`), the player stops, or the
  /// drawable is reattached. Those CALayer mutations must happen on the
  /// main thread; otherwise iOS raises
  /// `_raiseExceptionForBackgroundThreadLayerPropertyModification`.
  /// JS-driven lifecycle calls (release / replaceSourceAsync /
  /// constructor) can land on Nitro's worker thread, so we must hop
  /// before touching any `mediaPlayer.*` setter that triggers a render
  /// reset.
  @inline(__always)
  private static func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }

  init(source: (any HybridVideoPlayerSourceSpec)) throws {
    self.source = source
    self.eventEmitter = HybridVideoPlayerEventEmitter()
    self.mediaPlayer = VLCMediaPlayer()

    super.init()

    let delegates = VLCPlaybackDelegates(owner: self)
    self.vlcDelegates = delegates
    self.mediaPlayer.delegate = delegates

    if source.config.initializeOnCreation == true {
      attachMedia()
    }

    VideoManager.shared.register(player: self)
    startStallWatchdogIfNeeded()
  }

  deinit {
    invalidateStallWatchdog()
    release()
  }

  // MARK: - HybridVideoPlayerSpec

  var source: any HybridVideoPlayerSourceSpec

  var status: VideoPlayerStatus = .idle {
    didSet {
      if status != oldValue {
        _eventEmitter?.onStatusChange(status)
      }
    }
  }

  var eventEmitter: HybridVideoPlayerEventEmitterSpec
  var _eventEmitter: HybridVideoPlayerEventEmitter? {
    return eventEmitter as? HybridVideoPlayerEventEmitter
  }

  var volume: Double {
    set {
      let clamped = max(0, min(1, newValue))
      mediaPlayer.audio?.volume = Int32(clamped * 100)
      _eventEmitter?.onVolumeChange(
        onVolumeChangeData(volume: clamped, muted: muted)
      )
    }
    get {
      let v = Int(mediaPlayer.audio?.volume ?? 100)
      return Double(v) / 100.0
    }
  }

  private var _muted: Bool = false
  var muted: Bool {
    set {
      _muted = newValue
      mediaPlayer.audio?.setMute(newValue)
      _eventEmitter?.onVolumeChange(
        onVolumeChangeData(volume: volume, muted: newValue)
      )
    }
    get { _muted }
  }

  var currentTime: Double {
    set {
      let target = max(0, newValue)
      _eventEmitter?.onSeek(target)
      markUserInitiatedTransport()
      applySeek(seconds: target)
    }
    get {
      let ms = mediaPlayer.time.intValue
      if ms < 0 { return Double.nan }
      return Double(ms) / 1000.0
    }
  }

  var duration: Double {
    let ms = mediaPlayer.media?.length.intValue ?? 0
    if ms <= 0 { return Double.nan }
    return Double(ms) / 1000.0
  }

  var rate: Double {
    set {
      let clamped = max(0, newValue)
      mediaPlayer.rate = Float(clamped)
      lastReportedRate = clamped
      _eventEmitter?.onPlaybackRateChange(clamped)
    }
    get {
      return Double(mediaPlayer.rate)
    }
  }

  var loop: Bool = false

  var mixAudioMode: MixAudioMode = .auto {
    didSet { VideoManager.shared.requestAudioSessionUpdate() }
  }

  var ignoreSilentSwitchMode: IgnoreSilentSwitchMode = .auto {
    didSet { VideoManager.shared.requestAudioSessionUpdate() }
  }

  var playInBackground: Bool = false {
    didSet { VideoManager.shared.requestAudioSessionUpdate() }
  }

  var playWhenInactive: Bool = false

  var wasAutoPaused: Bool = false

  var isCurrentlyBuffering: Bool = false

  var isPlaying: Bool {
    return mediaPlayer.isPlaying
  }

  var showNotificationControls: Bool = false

  var preventsDisplaySleepDuringVideoPlayback: Bool = true

  func initialize() throws -> Promise<Void> {
    let promise = Promise<Void>()
    if media != nil {
      promise.resolve(withResult: ())
      return promise
    }
    attachMedia()
    promise.resolve(withResult: ())
    return promise
  }

  func release() {
    invalidateStallWatchdog()

    // Capture the VLC objects so they survive past `self` being
    // deallocated — `release()` may be called from `deinit` on a
    // background thread, and the closure below has to outlive the
    // `HybridVideoPlayer` instance.
    let mp = mediaPlayer
    let m = media
    let proxy = authProxy

    // Clear JS-side bookkeeping first; it doesn't touch any UIKit
    // layer state and can safely run on whatever thread we're on.
    media = nil
    vlcDelegates = nil
    authProxy = nil

    try? _eventEmitter?.clearAllListeners()

    wantsPlaybackWhenDrawableReady = false
    status = .idle
    hasFiredOnLoad = false
    hasFiredOnLoadStart = false
    pendingSeekSeconds = nil
    hasEmittedEndForCurrentItem = false
    reconnectAttempts = 0
    lastProgressTimeSeconds = 0
    lastProgressTickMonotonic = 0

    // Tear down VLC on the main thread. `mp.stop()` and
    // `mp.media = nil` cause `VLCOpenGLES2VideoView` to reset its
    // OpenGL renderbuffer, which mutates `CAEAGLLayer.contents` —
    // strictly main-thread-only. Without this hop, iOS raises
    // `_raiseExceptionForBackgroundThreadLayerPropertyModification`
    // whenever a player is released from a non-main queue (typical
    // when the JS owner is dropped from a Nitro worker thread).
    Self.runOnMain {
      if mp.isPlaying { mp.stop() }
      m?.delegate = nil
      mp.media = nil
      mp.delegate = nil
      proxy?.stop()
    }

    VideoManager.shared.unregister(player: self)
  }

  func preload() throws -> Promise<Void> {
    let promise = Promise<Void>()
    if media == nil {
      attachMedia()
    }
    promise.resolve(withResult: ())
    return promise
  }

  func play() throws {
    wantsPlaybackWhenDrawableReady = true
    let mp = mediaPlayer
    Self.runOnMain { mp.play() }
    VideoManager.shared.requestAudioSessionUpdate()
  }

  func pause() throws {
    wantsPlaybackWhenDrawableReady = false
    let mp = mediaPlayer
    // VLC's `stop()` (the not-canPause fallback) tears down the
    // renderbuffer; must be on main. Even `pause()` proper sometimes
    // touches the GL view on first call after attach, so keep both
    // branches on main for symmetry.
    Self.runOnMain {
      if mp.canPause {
        mp.pause()
      } else {
        mp.stop()
      }
    }
    VideoManager.shared.requestAudioSessionUpdate()
  }

  /// Called from `VideoComponentView` after `mediaPlayer.drawable` is set.
  func notifyVideoHostViewAttached() {
    if wantsPlaybackWhenDrawableReady, media != nil {
      mediaPlayer.play()
    }
    maybeFireOnLoad()
  }

  func seekBy(time: Double) throws {
    let cur = currentTime
    let base = cur.isFinite ? cur : 0
    let target = base + time
    let total = duration
    let bounded =
      total.isFinite && total > 0
      ? min(max(0, target), total)
      : max(0, target)
    currentTime = bounded
  }

  func seekTo(time: Double) {
    currentTime = time
  }

  func replaceSourceAsync(
    source: Variant_NullType__any_HybridVideoPlayerSourceSpec_?
  ) throws -> Promise<Void> {
    let promise = Promise<Void>()

    guard let source else {
      release()
      promise.resolve(withResult: ())
      return promise
    }

    switch source {
    case .first(_):
      release()
      promise.resolve(withResult: ())
    case .second(let newSource):
      wantsPlaybackWhenDrawableReady = false
      invalidateStallWatchdog()

      // Tear down the previous VLC media on main — same reasoning as
      // `release()`. `mediaPlayer.stop()` and `mediaPlayer.media = nil`
      // both poke `VLCOpenGLES2VideoView`'s renderbuffer.
      let mp = mediaPlayer
      let oldMedia = media
      let oldProxy = authProxy
      Self.runOnMain {
        if mp.isPlaying { mp.stop() }
        oldMedia?.delegate = nil
        mp.media = nil
        oldProxy?.stop()
      }
      media = nil
      authProxy = nil

      self.source = newSource
      hasFiredOnLoad = false
      hasFiredOnLoadStart = false
      pendingSeekSeconds = nil
      hasEmittedEndForCurrentItem = false
      reconnectAttempts = 0
      attachMedia()
      startStallWatchdogIfNeeded()
      promise.resolve(withResult: ())
    }

    return promise
  }

  func getAvailableTextTracks() throws -> [TextTrack] { return [] }

  func selectTextTrack(textTrack: Variant_NullType_TextTrack?) throws { /* no-op */ }

  var selectedTrack: TextTrack? { nil }

  func captureFrame() throws -> Promise<String> {
    let promise = Promise<String>()
    promise.reject(withError: PlayerError.notInitialized.error())
    return promise
  }

  func dispose() { release() }

  var memorySize: Int { 0 }

  // MARK: - VLCPlaybackDelegateOwner

  func vlcMediaPlayerStateDidChange() {
    handleStateChange()
  }

  func vlcMediaPlayerTimeDidChange() {
    handleTimeChange()
  }

  func vlcMediaMetaDataDidChange(_ media: VLCMedia) {
    _ = media
    flushPendingSeek()
    maybeFireOnLoad()
  }

  func vlcMediaDidFinishParsing(_ media: VLCMedia) {
    _ = media
    flushPendingSeek()
    maybeFireOnLoad()
  }

  // MARK: - Internal helpers

  private func attachMedia() {
    guard let hybridSource = source as? HybridVideoPlayerSource else {
      status = .error
      return
    }

    // Tear down any previous proxy before we (maybe) start a new one.
    authProxy?.stop()
    authProxy = nil

    var mediaURL = hybridSource.url
    var residualHeaders: [String: String] = [:]
    var bearerToken: String? = nil

    if let headers = hybridSource.config.headers, !headers.isEmpty {
      for (key, value) in headers {
        if key.lowercased() == "authorization" {
          // "Bearer xyz" or raw token — strip the scheme prefix; the
          // proxy re-prepends "Bearer " uniformly on forward.
          let trimmed = value.trimmingCharacters(in: .whitespaces)
          if trimmed.lowercased().hasPrefix("bearer ") {
            bearerToken = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
          } else {
            bearerToken = trimmed
          }
        } else {
          residualHeaders[key] = value
        }
      }
    }

    // libvlc 3.x has no `--http-header(s)`, so a JS-supplied Authorization
    // never reaches segment fetches. Route everything through a local
    // proxy that injects the bearer on each upstream request. UA / Referer
    // are still applied via the supported libvlc options below.
    if let token = bearerToken,
      let scheme = mediaURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      let proxy = HLSAuthProxy(originURL: mediaURL, bearerToken: token)
      do {
        try proxy.start()
        if let localURL = buildLocalProxyURL(from: mediaURL, port: proxy.port) {
          self.authProxy = proxy
          mediaURL = localURL
        } else {
          proxy.stop()
        }
      } catch {
        // Fall through with the original URL — playback will still fail
        // upstream, but at least the player surfaces VLC's own error
        // rather than a silent local-proxy failure.
      }
    }

    let media = VLCMedia(url: mediaURL)

    applyHlsNetworkOptions(to: media)

    for (key, value) in residualHeaders {
      switch key.lowercased() {
      case "user-agent":
        media.addOption(":http-user-agent=\(value)")
      case "referer", "referrer":
        media.addOption(":http-referrer=\(value)")
      default:
        // libvlc 3.x silently ignores arbitrary headers; skip rather than
        // pretending we forwarded them.
        break
      }
    }

    media.delegate = vlcDelegates
    self.media = media
    // Assigning `mediaPlayer.media` causes VLC to swap the active
    // `VLCOpenGLES2VideoView` renderbuffer, which mutates
    // `CAEAGLLayer.contents`. Hop to main so the layer write is on
    // the main thread. We capture `mediaPlayer` and the new `media`
    // by value so the assignment is safe even if `self` is dropped
    // before the dispatched block runs.
    let mp = mediaPlayer
    let mediaToAttach = media
    Self.runOnMain {
      mp.media = mediaToAttach
    }

    if !hasFiredOnLoadStart {
      hasFiredOnLoadStart = true
      // Classify by the *original* source URL, not the loopback rewrite —
      // a proxied https origin is still a network source.
      let isNetworkSource = !hybridSource.url.isFileURL
      _eventEmitter?.onLoadStart(
        onLoadStartData(
          sourceType: isNetworkSource ? .network : .local,
          source: hybridSource
        )
      )
    }

    status = .loading
    setBuffering(true)
    hasEmittedEndForCurrentItem = false
  }

  /// Rewrite an http(s) URL to point at the local auth proxy on
  /// 127.0.0.1:<port> while preserving path + query so VLC's relative
  /// segment resolution keeps targeting the proxy.
  private func buildLocalProxyURL(from origin: URL, port: UInt16) -> URL? {
    guard
      var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
    else { return nil }
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = Int(port)
    components.user = nil
    components.password = nil
    return components.url
  }

  private func applyHlsNetworkOptions(to media: VLCMedia) {
    media.addOption(":network-caching=\(VLCHLSDefaults.networkCachingMs)")
    media.addOption(":live-caching=\(VLCHLSDefaults.liveCachingMs)")
    // HLS over HTTP benefits from reconnect; harmless for file URLs.
    media.addOption(":http-reconnect=true")
  }

  /// Resets stall-watchdog liveness so a long seek / buffer gap is not mistaken for a dead stream.
  private func markUserInitiatedTransport() {
    lastProgressTickMonotonic = ProcessInfo.processInfo.systemUptime
  }

  private func applySeek(seconds target: Double) {
    let ms = Int32(min(Double(Int32.max), max(0, target * 1000.0)))

    // VLC's seek can prompt the demuxer to re-attach segments and
    // refresh the renderbuffer (especially for HLS where a seek
    // jumps to a different .ts segment). Marshal onto main so any
    // resulting CALayer write happens there. We capture the player
    // by value so the dispatch is safe even if the JS owner is
    // released before the block fires.
    let mp = mediaPlayer
    let totalMs = Double(media?.length.intValue ?? 0)
    let isSeekable = mediaPlayer.isSeekable

    if isSeekable {
      pendingSeekSeconds = nil
      Self.runOnMain { mp.time = VLCTime(int: ms) }
      return
    }

    if totalMs > 0 {
      let position = Float(min(1.0, (Double(ms)) / totalMs))
      pendingSeekSeconds = nil
      Self.runOnMain { mp.position = position }
    } else {
      pendingSeekSeconds = target
    }
  }

  private func handleStateChange() {
    let state = mediaPlayer.state
    switch state {
    case .opening:
      status = .loading
      setBuffering(true)

    case .buffering:
      markUserInitiatedTransport()
      setBuffering(true)
      if status != .readytoplay {
        status = .loading
      }

    case .playing:
      setBuffering(false)
      status = .readytoplay
      maybeFireOnLoad()
      flushPendingSeek()
      reconnectAttempts = 0
      VideoManager.shared.requestAudioSessionUpdate()

    case .paused:
      setBuffering(false)
      if status == .loading { status = .readytoplay }
      VideoManager.shared.requestAudioSessionUpdate()

    case .stopped, .ended:
      setBuffering(false)
      if !hasEmittedEndForCurrentItem {
        hasEmittedEndForCurrentItem = true
        _eventEmitter?.onEnd()
      }
      if loop {
        hasEmittedEndForCurrentItem = false
        currentTime = 0
        try? play()
      }

    case .error:
      setBuffering(false)
      status = .error
      // JS layer maps `error` status → `onError` (see VideoPlayer.ts).

    default:
      break
    }

    emitPlaybackState()
  }

  private func handleTimeChange() {
    let cur = currentTime
    let dur = duration
    if cur.isFinite {
      lastProgressTimeSeconds = cur
      lastProgressTickMonotonic = ProcessInfo.processInfo.systemUptime
    }

    _eventEmitter?.onProgress(
      onProgressData(
        currentTime: cur.isFinite ? cur : 0,
        duration: dur.isFinite ? dur : Double.nan,
        bufferDuration: 0
      )
    )
    flushPendingSeek()
    maybeFireOnLoad()
  }

  private func setBuffering(_ buffering: Bool) {
    isCurrentlyBuffering = buffering
  }

  private func emitPlaybackState() {
    let playing = mediaPlayer.isPlaying && !isCurrentlyBuffering
    if playing != lastEmittedIsPlaying || isCurrentlyBuffering != lastEmittedIsBuffering {
      lastEmittedIsPlaying = playing
      lastEmittedIsBuffering = isCurrentlyBuffering
      _eventEmitter?.onPlaybackStateChange(
        onPlaybackStateChangeData(isPlaying: playing, isBuffering: isCurrentlyBuffering)
      )
      _eventEmitter?.onBuffer(isCurrentlyBuffering)
    }
  }

  private func maybeFireOnLoad() {
    guard !hasFiredOnLoad else { return }
    let dur = duration
    let hasDuration = dur.isFinite && dur > 0
    let size = mediaPlayer.videoSize
    let hasVideo = size.width > 0 && size.height > 0
    // VOD HLS from MediaMTX may keep length at 0 until the playlist is fully
    // parsed; still emit onLoad once we are playing or have decoded dimensions
    // so JS overlays (e.g. preroll spinner) can clear.
    if !hasDuration && !mediaPlayer.isPlaying && !hasVideo {
      return
    }
    hasFiredOnLoad = true
    let width = Double(size.width)
    let height = Double(size.height)
    let orientation: VideoOrientation =
      height > width ? .portrait : (width > height ? .landscape : .square)
    let ct = currentTime
    _eventEmitter?.onLoad(
      onLoadData(
        currentTime: ct.isFinite ? ct : 0,
        duration: dur.isFinite ? dur : Double.nan,
        height: height,
        width: width,
        orientation: orientation
      )
    )
    _eventEmitter?.onReadyToDisplay()
  }

  private func flushPendingSeek() {
    guard let target = pendingSeekSeconds else { return }
    applySeek(seconds: target)
  }

  // MARK: - Stall detection + reconnect

  private func startStallWatchdogIfNeeded() {
    invalidateStallWatchdog()
    let timer = Timer.scheduledTimer(withTimeInterval: Self.stallCheckIntervalSeconds, repeats: true) {
      [weak self] _ in
      self?.evaluatePlaybackStall()
    }
    RunLoop.main.add(timer, forMode: .common)
    stallCheckTimer = timer
  }

  private func invalidateStallWatchdog() {
    stallCheckTimer?.invalidate()
    stallCheckTimer = nil
  }

  private func evaluatePlaybackStall() {
    guard media != nil else { return }
    guard mediaPlayer.isPlaying else { return }
    guard !isCurrentlyBuffering else { return }
    guard status == .readytoplay else { return }

    let now = ProcessInfo.processInfo.systemUptime
    let idle = now - lastProgressTickMonotonic
    guard idle > Self.stallNoProgressSeconds else { return }

    // Genuine stall: VLC still claims "playing" but time is not advancing.
    trySoftRecovery()
  }

  private func trySoftRecovery() {
    let savedTime = lastProgressTimeSeconds

    mediaPlayer.pause()
    mediaPlayer.play()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard let self else { return }
      guard self.mediaPlayer.isPlaying else { return }
      let progressed =
        abs(self.lastProgressTimeSeconds - savedTime) > 0.25
      if !progressed {
        self.performAutoReconnect(resumeNear: savedTime)
      } else {
        self.reconnectAttempts = 0
      }
    }
  }

  private func performAutoReconnect(resumeNear seconds: Double) {
    guard reconnectAttempts < Self.maxAutoReconnects else { return }
    reconnectAttempts += 1
    markUserInitiatedTransport()

    let resume = max(0, seconds)
    guard let hybridSource = source as? HybridVideoPlayerSource else { return }

    mediaPlayer.stop()
    media?.delegate = nil
    media = nil
    mediaPlayer.media = nil

    hasFiredOnLoad = false
    hasEmittedEndForCurrentItem = false

    attachMedia()
    mediaPlayer.play()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self else { return }
      self.currentTime = resume
    }
  }

}
