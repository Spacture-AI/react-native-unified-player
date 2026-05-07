//
//  HybridVideoPlayer.swift
//  ReactNativeVideo
//
//  Created by Krzysztof Moch on 09/10/2024.
//  VLC backend rewrite — replaces AVPlayer with MobileVLCKit.
//

import Foundation
import MobileVLCKit
import NitroModules

final class HybridVideoPlayer: HybridVideoPlayerSpec {

  public let mediaPlayer: VLCMediaPlayer
  private var media: VLCMedia?
  private var vlcDelegate: VLCDelegateProxy?

  // Cached state — VLC doesn't surface every property as a getter we can poll
  // safely from arbitrary threads, so we mirror what JS asks for.
  private var lastReportedRate: Double = 1.0
  private var hasFiredOnLoad: Bool = false
  private var hasFiredOnLoadStart: Bool = false
  private var lastEmittedIsPlaying: Bool = false
  private var lastEmittedIsBuffering: Bool = false
  private var pendingSeekSeconds: Double? = nil

  init(source: (any HybridVideoPlayerSourceSpec)) throws {
    self.source = source
    self.eventEmitter = HybridVideoPlayerEventEmitter()
    self.mediaPlayer = VLCMediaPlayer()

    super.init()

    let proxy = VLCDelegateProxy(owner: self)
    self.vlcDelegate = proxy
    self.mediaPlayer.delegate = proxy

    if source.config.initializeOnCreation == true {
      attachMedia()
    }

    VideoManager.shared.register(player: self)
  }

  deinit {
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
      // VLC audio.volume is 0...100
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
      _eventEmitter?.onSeek(newValue)
      let target = max(0, newValue)
      let totalMs = Double(mediaPlayer.media?.length.intValue ?? 0)
      if totalMs > 0 {
        let position = Float(min(1.0, (target * 1000.0) / totalMs))
        mediaPlayer.position = position
      } else {
        // Live / unknown duration — defer seek until media reports length
        pendingSeekSeconds = target
      }
    }
    get {
      let ms = mediaPlayer.time.intValue
      return Double(ms) / 1000.0
    }
  }

  var duration: Double {
    let ms = mediaPlayer.media?.length.intValue ?? 0
    return Double(ms) / 1000.0
  }

  var rate: Double {
    set {
      mediaPlayer.rate = Float(newValue)
      lastReportedRate = newValue
      _eventEmitter?.onPlaybackRateChange(newValue)
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

  // VLC doesn't expose preventsDisplaySleepDuringVideoPlayback equivalent;
  // the view layer handles UIApplication.idleTimerDisabled instead.
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
    if mediaPlayer.isPlaying {
      mediaPlayer.stop()
    }
    media = nil
    mediaPlayer.media = nil
    mediaPlayer.delegate = nil
    vlcDelegate = nil

    try? _eventEmitter?.clearAllListeners()

    status = .idle
    hasFiredOnLoad = false
    hasFiredOnLoadStart = false
    pendingSeekSeconds = nil

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
    mediaPlayer.play()
  }

  func pause() throws {
    if mediaPlayer.canPause {
      mediaPlayer.pause()
    } else {
      mediaPlayer.stop()
    }
  }

  func seekBy(time: Double) throws {
    let target = currentTime + time
    let total = duration
    let bounded = total.isFinite && total > 0 ? min(max(0, target), total) : max(0, target)
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
      self.source = newSource
      hasFiredOnLoad = false
      hasFiredOnLoadStart = false
      pendingSeekSeconds = nil
      attachMedia()
      promise.resolve(withResult: ())
    }

    return promise
  }

  // MARK: - Text tracks (VLC supports embedded tracks; external subtitles
  // and full track APIs are out of scope for this iteration.)

  func getAvailableTextTracks() throws -> [TextTrack] { return [] }

  func selectTextTrack(textTrack: Variant_NullType_TextTrack?) throws { /* no-op */ }

  var selectedTrack: TextTrack? { nil }

  // MARK: - Frame capture (out of scope for VLC backend)

  func captureFrame() throws -> Promise<String> {
    let promise = Promise<String>()
    promise.reject(withError: PlayerError.notInitialized.error())
    return promise
  }

  // MARK: - Memory

  func dispose() { release() }

  var memorySize: Int { 0 }

  // MARK: - Internal helpers

  private func attachMedia() {
    guard let hybridSource = source as? HybridVideoPlayerSource else {
      status = .error
      return
    }

    let url = hybridSource.url
    let media = VLCMedia(url: url)

    if let headers = hybridSource.config.headers, !headers.isEmpty {
      // VLC doesn't expose an HTTP-headers API as plainly as AVURLAsset.
      // The most reliable channel is the per-media `--http-*` options.
      // We stash the Authorization header (the only one Spacture sends) via
      // `:http-user-agent` and `:http-referrer` style options where they
      // map cleanly, and fall back to a single concatenated header line for
      // anything else.
      for (key, value) in headers {
        let lower = key.lowercased()
        switch lower {
        case "user-agent":
          media.addOption(":http-user-agent=\(value)")
        case "referer", "referrer":
          media.addOption(":http-referrer=\(value)")
        default:
          // libvlc accepts arbitrary HTTP headers via --http-header on
          // recent builds; it's safe to pass and ignored on older ones.
          media.addOption(":http-header=\(key): \(value)")
        }
      }
    }

    self.media = media
    mediaPlayer.media = media

    if !hasFiredOnLoadStart {
      hasFiredOnLoadStart = true
      let isNetworkSource = !url.isFileURL
      _eventEmitter?.onLoadStart(
        onLoadStartData(
          sourceType: isNetworkSource ? .network : .local,
          source: hybridSource
        )
      )
    }

    status = .loading
    setBuffering(true)
  }

  // MARK: - VLCMediaPlayerDelegate routing (via VLCDelegateProxy)

  fileprivate func handleStateChange() {
    let state = mediaPlayer.state
    switch state {
    case .opening:
      status = .loading
      setBuffering(true)

    case .buffering:
      // VLC fires .buffering both at initial load and during playback when
      // the buffer drains. If the player is already playing, treat as
      // genuine buffering; if it isn't, treat as load-progress.
      setBuffering(true)
      status = .loading

    case .playing:
      setBuffering(false)
      status = .readytoplay
      maybeFireOnLoad()
      flushPendingSeek()

    case .paused:
      setBuffering(false)
      // Keep status as readytoplay — we're loaded, just not advancing.
      if status == .loading { status = .readytoplay }

    case .stopped, .ended:
      setBuffering(false)
      _eventEmitter?.onEnd()
      if loop {
        currentTime = 0
        try? play()
      }

    case .error:
      setBuffering(false)
      status = .error

    default:
      break
    }

    emitPlaybackState()
  }

  fileprivate func handleTimeChange() {
    let cur = currentTime
    let dur = duration
    _eventEmitter?.onProgress(
      onProgressData(
        currentTime: cur,
        duration: dur,
        // VLC's buffer position isn't exposed as a duration value; report 0.
        bufferDuration: 0
      )
    )
    // Once we have a non-zero duration, fulfill any deferred seeks.
    flushPendingSeek()
    maybeFireOnLoad()
  }

  // MARK: - Helpers

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
    if dur <= 0 && !mediaPlayer.isPlaying {
      // Not enough info yet — wait for a later tick.
      return
    }
    hasFiredOnLoad = true
    let size = mediaPlayer.videoSize
    let width = Double(size.width)
    let height = Double(size.height)
    let orientation: VideoOrientation =
      height > width ? .portrait : (width > height ? .landscape : .square)
    _eventEmitter?.onLoad(
      onLoadData(
        currentTime: currentTime,
        duration: dur,
        height: height,
        width: width,
        orientation: orientation
      )
    )
    _eventEmitter?.onReadyToDisplay()
  }

  private func flushPendingSeek() {
    guard let target = pendingSeekSeconds else { return }
    let totalMs = Double(mediaPlayer.media?.length.intValue ?? 0)
    if totalMs > 0 {
      let position = Float(min(1.0, (target * 1000.0) / totalMs))
      mediaPlayer.position = position
      pendingSeekSeconds = nil
    }
  }
}

/// NSObject proxy bridging VLCMediaPlayerDelegate (Obj-C protocol) to the
/// Swift-only HybridVideoPlayer. HybridVideoPlayer cannot conform directly
/// because its base class chain isn't guaranteed to inherit from NSObject.
final class VLCDelegateProxy: NSObject, VLCMediaPlayerDelegate {
  private weak var owner: HybridVideoPlayer?

  init(owner: HybridVideoPlayer) {
    self.owner = owner
  }

  func mediaPlayerStateChanged(_ aNotification: Notification) {
    owner?.handleStateChange()
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    owner?.handleTimeChange()
  }
}
