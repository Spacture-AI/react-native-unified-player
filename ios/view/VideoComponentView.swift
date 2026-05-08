//
//  VideoComponent.swift
//  ReactNativeVideo
//
//  Created by Krzysztof Moch on 30/09/2024.
//  VLC backend rewrite — replaces AVPlayerViewController with a UIView that
//  serves as the VLCMediaPlayer drawable.
//

import Foundation
import MobileVLCKit
import UIKit

@objc public class VideoComponentView: UIView {
  public weak var player: HybridVideoPlayerSpec? = nil {
    didSet {
      attachCurrentPlayer()
    }
  }

  var delegate: VideoViewDelegate?

  /// The UIView VLC renders into. We keep this distinct from `self` so that
  /// resize-mode adjustments only affect the video surface, not the
  /// container's interaction targets / overlays.
  private var drawableView: UIView!

  private var _keepScreenAwake: Bool = false
  var keepScreenAwake: Bool {
    get { _keepScreenAwake }
    set {
      _keepScreenAwake = newValue
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = newValue
      }
    }
  }

  /// Controls overlay isn't supported on the VLC backend; the prop is
  /// preserved for API compat but is a no-op.
  public var controls: Bool = false

  public var allowsPictureInPicturePlayback: Bool = false
  public var autoEnterPictureInPicture: Bool = false

  public var resizeMode: ResizeMode = .none {
    didSet { applyResizeMode() }
  }

  /// Track if we need to send pending nitroId change event
  private var pendingNitroIdEvent = false

  @objc public var onNitroIdChange: (([String: Any]) -> Void)? {
    didSet {
      if pendingNitroIdEvent, let callback = onNitroIdChange {
        callback(["nitroId": nitroId])
        pendingNitroIdEvent = false
      }
    }
  }

  @objc public var nitroId: NSNumber = -1 {
    didSet {
      VideoComponentView.globalViewsMap.setObject(self, forKey: nitroId)
      if let callback = onNitroIdChange {
        callback(["nitroId": nitroId])
        pendingNitroIdEvent = false
      } else {
        pendingNitroIdEvent = true
      }
    }
  }

  @objc public static var globalViewsMap: NSMapTable<NSNumber, VideoComponentView> =
    .strongToWeakObjects()

  @objc public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    VideoManager.shared.register(view: self)
    setupDrawableView()
  }

  deinit {
    VideoManager.shared.unregister(view: self)
  }

  @objc public required init?(coder: NSCoder) {
    super.init(coder: coder)
    backgroundColor = .black
    setupDrawableView()
  }

  func setNitroId(nitroId: NSNumber) {
    self.nitroId = nitroId
  }

  private func setupDrawableView() {
    drawableView = UIView(frame: bounds)
    drawableView.backgroundColor = .black
    drawableView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(drawableView)
    NSLayoutConstraint.activate([
      drawableView.leadingAnchor.constraint(equalTo: leadingAnchor),
      drawableView.trailingAnchor.constraint(equalTo: trailingAnchor),
      drawableView.topAnchor.constraint(equalTo: topAnchor),
      drawableView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func attachCurrentPlayer() {
    guard let hybridPlayer = player as? HybridVideoPlayer else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      hybridPlayer.mediaPlayer.drawable = self.drawableView
      self.applyResizeMode()
      // `play()` may have run from JS before this view existed; VLC needs a
      // drawable to complete HLS decode on iOS — kick playback again here.
      hybridPlayer.notifyVideoHostViewAttached()
    }
  }

  private func applyResizeMode() {
    guard let hybridPlayer = player as? HybridVideoPlayer else { return }
    let mediaPlayer = hybridPlayer.mediaPlayer
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      switch self.resizeMode {
      case .contain, .none:
        // VLC default: fit-aspect (letterbox). scaleFactor=0 = auto.
        mediaPlayer.scaleFactor = 0
      case .cover, .stretch:
        // Both modes fill the view. We compute scaleFactor from the ratio
        // of view-aspect to video-aspect so the smaller side scales up to
        // hide the letterbox. With VLC there's no clean way to anisotropic-
        // scale through public API without char* lifetime gymnastics, so
        // .stretch is approximated by .cover (visually identical for any
        // source whose aspect roughly matches the view).
        let viewSize = self.bounds.size
        let videoSize = mediaPlayer.videoSize
        guard
          viewSize.width > 0, viewSize.height > 0,
          videoSize.width > 0, videoSize.height > 0
        else {
          mediaPlayer.scaleFactor = 0
          return
        }
        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height
        let scale: CGFloat = viewAspect > videoAspect
          ? viewAspect / videoAspect
          : videoAspect / viewAspect
        mediaPlayer.scaleFactor = Float(scale)
      }
    }
  }

  public override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview == nil {
      if keepScreenAwake { keepScreenAwake = false }
    } else if _keepScreenAwake {
      keepScreenAwake = true
    }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    // Reapply resize mode whenever bounds change so cover/stretch math stays
    // in sync with the new aspect ratio.
    applyResizeMode()
  }

  // MARK: - Fullscreen / PiP — not supported on the VLC backend

  public func enterFullscreen() throws {
    throw VideoViewError.viewIsDeallocated.error()
  }

  public func exitFullscreen() throws {
    throw VideoViewError.viewIsDeallocated.error()
  }

  public func startPictureInPicture() throws {
    throw VideoViewError.pictureInPictureNotSupported.error()
  }

  public func stopPictureInPicture() throws {
    throw VideoViewError.pictureInPictureNotSupported.error()
  }

  // MARK: - Fullscreen lifecycle hooks (kept for API compat)

  func onEnterFullscreen() { /* no-op */ }
  func onExitFullscreen() { /* no-op */ }
}
