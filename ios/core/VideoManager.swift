//
//  VideoManager.swift
//  ReactNativeVideo
//
//  VLC backend rewrite — keeps a registry of live players/views and a
//  minimal AVAudioSession configuration so audio routes correctly. All
//  AVPlayer-specific logic (external playback, NowPlaying integration,
//  audiovisualBackgroundPlaybackPolicy, etc.) was removed.
//

import AVFoundation
import Foundation
import UIKit

class VideoManager {
  static let shared = VideoManager()

  private var players = NSHashTable<HybridVideoPlayer>.weakObjects()
  private var videoView = NSHashTable<VideoComponentView>.weakObjects()

  private var isAudioSessionActive = false
  private var isAudioSessionManagementDisabled: Bool = false

  private init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillResignActive(notification:)),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive(notification:)),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground(notification:)),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillEnterForeground(notification:)),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func register(player: HybridVideoPlayer) {
    players.add(player)
  }

  func unregister(player: HybridVideoPlayer) {
    players.remove(player)
  }

  func register(view: VideoComponentView) {
    videoView.add(view)
  }

  func unregister(view: VideoComponentView) {
    videoView.remove(view)
  }

  func requestAudioSessionUpdate() {
    updateAudioSessionConfiguration()
  }

  // MARK: - Audio Session Management

  private func activateAudioSession() {
    if isAudioSessionActive { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      isAudioSessionActive = true
    } catch {
      print("UnifiedPlayer: Failed to activate audio session: \(error.localizedDescription)")
    }
  }

  private func deactivateAudioSession() {
    if !isAudioSessionActive { return }
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation
      )
      isAudioSessionActive = false
    } catch {
      print("UnifiedPlayer: Failed to deactivate audio session: \(error.localizedDescription)")
    }
  }

  private func updateAudioSessionConfiguration() {
    if isAudioSessionManagementDisabled { return }

    let isAnyPlayerPlaying = players.allObjects.contains { player in
      !player.muted && player.isPlaying
    }
    let anyPlayerNeedsBackground = players.allObjects.contains { $0.playInBackground }

    if isAnyPlayerPlaying || anyPlayerNeedsBackground {
      activateAudioSession()
    } else {
      deactivateAudioSession()
    }

    configureAudioSession()
  }

  private func configureAudioSession() {
    if isAudioSessionManagementDisabled { return }

    let audioSession = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = audioSession.categoryOptions

    let anyPlayerNeedsObey = players.allObjects.contains { $0.ignoreSilentSwitchMode == .obey }

    let mixingMode = determineAudioMixingMode()
    switch mixingMode {
    case .mixwithothers:
      options.insert(.mixWithOthers)
    case .donotmix:
      options.remove(.mixWithOthers)
    case .duckothers:
      options.insert(.duckOthers)
    case .auto:
      options.remove(.mixWithOthers)
      options.remove(.duckOthers)
    }

    let category: AVAudioSession.Category = anyPlayerNeedsObey ? .ambient : .playback

    do {
      try audioSession.setCategory(category, mode: .moviePlayback, options: options)
    } catch {
      print("UnifiedPlayer: Failed to set audio session category: \(error.localizedDescription)")
    }
  }

  private func determineAudioMixingMode() -> MixAudioMode {
    let active = players.allObjects.filter { $0.isPlaying && !$0.muted }
    if active.isEmpty { return .mixwithothers }

    if active.contains(where: { $0.mixAudioMode == .donotmix }) { return .donotmix }
    if active.contains(where: { $0.mixAudioMode == .auto }) { return .auto }
    if active.contains(where: { $0.mixAudioMode == .duckothers }) { return .duckothers }
    return .mixwithothers
  }

  // MARK: - Notification handlers

  @objc
  private func handleAudioSessionInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    switch type {
    case .began:
      break
    case .ended:
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let resumeOptions = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if resumeOptions.contains(.shouldResume) {
          updateAudioSessionConfiguration()
        }
      }
    @unknown default:
      break
    }
  }

  @objc func applicationWillResignActive(notification: Notification) {
    for player in players.allObjects {
      if player.playInBackground || player.playWhenInactive || !player.isPlaying { continue }
      try? player.pause()
      player.wasAutoPaused = true
    }
  }

  @objc func applicationDidBecomeActive(notification: Notification) {
    for player in players.allObjects where player.wasAutoPaused {
      try? player.play()
      player.wasAutoPaused = false
    }
  }

  @objc func applicationDidEnterBackground(notification: Notification) {
    for player in players.allObjects {
      if player.playInBackground || !player.isPlaying { continue }
      try? player.pause()
      player.wasAutoPaused = true
    }
  }

  @objc func applicationWillEnterForeground(notification: Notification) {
    for player in players.allObjects where player.wasAutoPaused {
      try? player.play()
      player.wasAutoPaused = false
    }
  }
}
