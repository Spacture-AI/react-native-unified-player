# iOS playback: MobileVLCKit architecture

This document describes the iOS HLS stack in `react-native-unified-player` after the AVPlayer → MobileVLCKit migration, how it maps to the public JS API, and how it behaves with MediaMTX-style manifests (`.m3u8` + relative `.ts` segments).

## Architecture

| Layer | Responsibility |
|--------|------------------|
| `HybridVideoPlayer.swift` | Nitro hybrid: `VLCMedia` + `VLCMediaPlayer`, playback state, seek, buffering flags, stall watchdog, auto-reconnect, events. |
| `VLCPlaybackDelegates.swift` | `NSObject` implementing `VLCMediaPlayerDelegate` + `VLCMediaDelegate`, weak owner, main-thread delivery. |
| `VideoComponentView.swift` | Host `UIView` for `mediaPlayer.drawable`; resize modes; idle timer; PiP/fullscreen API compatibility (throws or no-op where VLC cannot support). |
| `VideoManager.swift` | App lifecycle + `AVAudioSession` (category / activation). No AVPlayer. |
| `HybridVideoPlayerSource.swift` | Resolves `uri` to `URL` (absolute playlist URL). VLC resolves relative segment URLs against this base. |
| `VideoPlayer.ts` | Subscribes to `onStatusChange` and surfaces a transition into `error` as `onError` for apps that only listen to `onError`. |

## HLS / MediaMTX

- Pass the **full absolute** manifest URL (`https://…/index.m3u8`). Relative `#EXTINF` segment lines are resolved by libvlc against that URL; no extra native work is required for `/path/segment.ts` style entries.
- Default libvlc options applied in `applyHlsNetworkOptions`: `:network-caching`, `:live-caching`, `:http-reconnect=true`. Tune `VLCHLSDefaults` in `HybridVideoPlayer.swift` if you need a more aggressive live edge or larger VOD buffer.
- **EXT-X-PROGRAM-DATE-TIME**: Wall-clock alignment remains the responsibility of the JS/VMS layer (as in Spacture `PlaybackPlayer` + parent UTC mapping). MobileVLCKit does not expose a stable, cross-version stream of raw HLS tags to Nitro; do not rely on native P-DT parsing here.

### Auth (`Authorization` header)

libvlc 3.x — what `MobileVLCKit ~> 3.7.x` ships — has no `--http-header(s)` option, so a JS-supplied `Authorization` cannot be passed straight to VLC's HTTP access module: it would be silently dropped on every `.ts` segment fetch. To make bearer auth actually work we run a small in-process HTTP/1.1 proxy on `127.0.0.1:<random-port>` (`HLSAuthProxy.swift`, started lazily in `attachMedia`):

1. The source URL is rewritten to `http://127.0.0.1:<port>/<original-path>?<original-query>`.
2. VLC fetches the manifest from the proxy; the proxy forwards to the real origin with `Authorization: Bearer <token>` injected.
3. Relative + root-relative segment URIs in the manifest resolve against the loopback URL, so segment fetches go through the proxy too and pick up the same auth.

Only `Authorization` triggers the proxy. `User-Agent` / `Referer` headers go through the native `http-user-agent` / `http-referrer` options. Other custom headers are dropped (libvlc 3.x has no general path for them).

We previously tried `VLCKit 4.0.0a19` for native `--http-headers`, but that option string is not actually compiled into the alpha binary, and the alpha hits a `libvlc_media_retain(NULL)` assertion under HLS load. Revisit once a stable libvlc-4 build ships the option.

## Seeking

- Prefer **`VLCMediaPlayer.time`** when `isSeekable` is true (typical VOD HLS once parsed).
- Fall back to **`position`** (0…1) when duration/length is known but time-based seek is not yet available.
- If length is still unknown (e.g. early load), seeks are **deferred** (`pendingSeekSeconds`) until parsing advances enough to apply them.

## Buffering & stall recovery

- VLC state `.buffering` drives `isCurrentlyBuffering` and `onBuffer` / `onPlaybackStateChange`.
- A **main-runloop timer** detects “playing” with no `mediaPlayerTimeChanged` progress for several seconds, then:
  1. Soft recovery: `pause` + `play`.
  2. If still stuck: **auto-reconnect** (same URI, bounded attempts), then seek near the last known time.

There are **no separate Nitro events** named `onStall` / `onReconnect`; recovery is internal. Use `onBuffer`, `onPlaybackStateChange`, and `onStatusChange` for observability.

## Events (API contract)

Existing Nitro events are unchanged: `onLoadStart`, `onLoad`, `onReadyToDisplay`, `onProgress`, `onSeek`, `onBuffer`, `onPlaybackStateChange`, `onPlaybackRateChange`, `onVolumeChange`, `onEnd`, `onStatusChange`, `onTimedMetadata`, etc.

**`onError` (JS-only)** is now also invoked when native status becomes **`error`** (parity with how failures surface in-app). The payload is a `VideoRuntimeError` with code `unknown/unknown` and a generic message unless a thrown native error was already parsed elsewhere.

## Known VLC / product limitations

- **Picture-in-picture / fullscreen helpers** on the Fabric view throw or no-op; VMS layouts that only use inline `UnifiedPlayerView` are unaffected.
- **`bufferDuration` in `onProgress`** is currently always `0` on iOS (libvlc does not expose ExoPlayer-style buffered ranges through the stable Swift API used here).
- **Text tracks / `captureFrame`**: not implemented on the VLC path; APIs remain but return empty / reject as before.
- **FairPlay / DRM**: remains in the separate DRM plugin path (AVFoundation-based); do not assume DRM on the VLC engine.

## Testing checklist

- [ ] VOD HLS: play, pause, seek across segment boundaries, loop (if used).
- [ ] Auth: `Authorization` reaches both the manifest and `.ts` segments via the loopback `HLSAuthProxy`; UA / Referer reach upstream via the native libvlc options.
- [ ] Background: `playInBackground` / `playWhenInactive` vs `VideoManager` auto-pause behavior.
- [ ] Airplane toggle / mid-playback drop: expect stall recovery or `error` + `onError` after unrecoverable failure.
- [ ] Rapid mount/unmount: no crashes, timers invalidated in `release()`.
- [ ] Memory Instruments: no retain cycles (`VLCPlaybackDelegates` → weak owner; media delegate cleared on teardown).

## Rollout risks

- **libvlc version skew** across MobileVLCKit releases can change HLS edge behavior; pin the pod (`UnifiedPlayer.podspec` uses `MobileVLCKit ~> 3.6.0`).
- **Stall watchdog** may rarely false-trigger on extremely low frame-rate or frozen content; adjust `stallNoProgressSeconds` if needed.
- **Stricter `duration`/`currentTime` as `NaN`** when unknown improves spec alignment vs always `0`; confirm callers use `Number.isFinite`.

## Suggested follow-ups

- Plumb optional **buffer metrics** if a supported statistics API is confirmed for your pinned VLCKit build.
- Optional Nitro fields for **last native error string** and explicit **`onReconnect`** if product wants telemetry without inferring from `onLoad`/`onSeek` bursts.
