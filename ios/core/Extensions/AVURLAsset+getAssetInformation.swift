import AVFoundation

extension AVURLAsset {
  func getAssetInformation() async throws -> VideoInformation {
    var bitrate: Double = .nan
    var width: Double = .nan
    var height: Double = .nan
    var durationSeconds: Int64 = -1
    var isHDR = false
    var isLive = false
    var orientation: VideoOrientation = .unknown

    let fileSize = try await VideoFileHelper.getFileSize(for: url)

    if duration.flags.contains(.indefinite) {
      durationSeconds = -1
      isLive = true
    } else {
      durationSeconds = Int64(CMTimeGetSeconds(duration))
      isLive = false
    }

    if let videoTrack = tracks(withMediaType: .video).first {
      let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
      width = size.width
      height = size.height
      bitrate = Double(videoTrack.estimatedDataRate)
      orientation = videoTrack.orientation

      if #available(iOS 14.0, tvOS 14.0, visionOS 1.0, *) {
        isHDR = videoTrack.hasMediaCharacteristic(.containsHDRVideo)
      }
    } else if url.pathExtension == "m3u8" {
      // For HLS streams, we cannot get video track information directly,
      // so we download the manifest and try to extract video info from it.
      let manifestContent = try await HLSManifestParser.downloadManifest(from: url)
      let manifestInfo = try HLSManifestParser.parseM3U8Manifest(manifestContent)

      if let videoStream = manifestInfo.streams.first {
        width = Double(videoStream.width ?? Int(Double.nan))
        height = Double(videoStream.height ?? Int(Double.nan))
        bitrate = Double(videoStream.bandwidth ?? Int(Double.nan))
      }

      if width > 0 && height > 0 {
        if width == height {
          orientation = .square
        } else if width > height {
          orientation = .landscapeRight
        } else {
          orientation = .portrait
        }
      }
    }

    return VideoInformation(
      bitrate: bitrate,
      width: width,
      height: height,
      duration: durationSeconds,
      fileSize: fileSize,
      isHDR: isHDR,
      isLive: isLive,
      orientation: orientation
    )
  }
}
