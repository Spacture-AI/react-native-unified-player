import * as React from 'react';
import type { ViewProps, ViewStyle } from 'react-native';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { NitroModules } from 'react-native-nitro-modules';
import type { ListenerSubscription } from '../../spec/nitro/VideoPlayerEventEmitter.nitro';
import type {
  SurfaceType,
  VideoViewViewManager,
  VideoViewViewManagerFactory,
} from '../../spec/nitro/VideoViewViewManager.nitro';
import { type VideoViewEvents } from '../types/Events';
import type { ResizeMode } from '../types/ResizeMode';
import {
  tryParseNativeVideoError,
  VideoComponentError,
  VideoError,
} from '../types/VideoError';
import type { VideoPlayerStatus } from '../types/VideoPlayerStatus';
import type { VideoPlayer } from '../VideoPlayer';
import { NativeVideoView } from './NativeVideoView';

export interface VideoViewProps extends Partial<VideoViewEvents>, ViewProps {
  /**
   * The player to play the video - {@link VideoPlayer}
   */
  player: VideoPlayer;
  /**
   * The style of the video view - {@link ViewStyle}
   */
  style?: ViewStyle;
  /**
   * Whether to show the controls. Defaults to false.
   */
  controls?: boolean;
  /**
   * Whether to enable & show the picture in picture button in native controls. Defaults to false.
   */
  pictureInPicture?: boolean;
  /**
   * Whether to automatically enter picture in picture mode when the video is playing. Defaults to false.
   */
  autoEnterPictureInPicture?: boolean;
  /**
   * How the video should be resized to fit the view. Defaults to 'none'.
   * - 'contain': Scale the video uniformly (maintain aspect ratio) so that it fits entirely within the view
   * - 'cover': Scale the video uniformly (maintain aspect ratio) so that it fills the entire view (may crop)
   * - 'stretch': Scale the video to fill the entire view without maintaining aspect ratio
   * - 'none': Do not resize the video
   */
  resizeMode?: ResizeMode;
  /**
   * Whether to keep the screen awake while the video view is mounted. Defaults to true.
   */
  keepScreenAwake?: boolean;

  /**
   * The type of underlying native view. Defaults to 'surface'.
   * - 'surface': Uses a SurfaceView on Android. More performant, but cannot be animated or transformed.
   * - 'texture': Uses a TextureView on Android. Less performant, but can be animated and transformed.
   *
   * Only applicable on Android
   *
   * @default 'surface'
   * @platform android
   */
  surfaceType?: SurfaceType;
  /**
   * Whether to automatically start playing the video when loaded. Defaults to true.
   */
  autoplay?: boolean;
  /**
   * Whether the video should be displayed in fullscreen mode.
   * Set to true to enter fullscreen, false to exit fullscreen.
   */
  fullscreen?: boolean;
  /**
   * Whether the video acts as paused.
   * - true: Pause the video
   * - false: Play the video
   */
  paused?: boolean;
  /**
   * The playback speed of the video. Defaults to 1.0.
   */
  speed?: number;
  /**
   * When true, shows a centered activity indicator while the source is
   * loading or the native player reports buffering (initial load and rebuffer).
   * @default false
   */
  showLoadingIndicator?: boolean;
  /**
   * @platform ios
   */
  loadingIndicatorColor?: string;
}

export interface VideoViewRef {
  /**
   * Enter fullscreen mode
   */
  enterFullscreen: () => void;
  /**
   * Exit fullscreen mode
   */
  exitFullscreen: () => void;
  /**
   * Enter picture in picture mode
   */
  enterPictureInPicture: () => void;
  /**
   * Exit picture in picture mode
   */
  exitPictureInPicture: () => void;
  /**
   * Check if picture in picture mode is supported
   * @returns true if picture in picture mode is supported, false otherwise
   */
  canEnterPictureInPicture: () => boolean;
  /**
   * Adds a listener for a view event.
   * @param event - The event to add a listener for.
   * @param callback - The callback to call when the event is triggered.
   * @returns A subscription object that can be used to remove the listener.
   */
  addEventListener: <Event extends keyof VideoViewEvents>(
    event: Event,
    callback: VideoViewEvents[Event]
  ) => ListenerSubscription;
}

let nitroIdCounter = 1;
const VideoViewViewManagerFactory =
  NitroModules.createHybridObject<VideoViewViewManagerFactory>(
    'VideoViewViewManagerFactory'
  );

const wrapNativeViewManagerFunction = <T,>(
  manager: VideoViewViewManager | null,
  func: (manager: VideoViewViewManager) => T
) => {
  try {
    if (manager === null) {
      throw new VideoError('view/not-found', 'View manager not found');
    }

    return func(manager);
  } catch (error) {
    throw tryParseNativeVideoError(error);
  }
};

const updateProps = (manager: VideoViewViewManager, props: VideoViewProps) => {
  manager.player = props.player.__getNativePlayer();
  manager.controls = props.controls ?? false;
  manager.pictureInPicture = props.pictureInPicture ?? false;
  manager.autoEnterPictureInPicture = props.autoEnterPictureInPicture ?? false;
  manager.resizeMode = props.resizeMode ?? 'none';
  manager.keepScreenAwake = props.keepScreenAwake ?? true;
  manager.surfaceType = props.surfaceType ?? 'surface';
};

/**
 * VideoView is a component that allows you to display a video from a {@link VideoPlayer}.
 *
 * @param player - The player to play the video - {@link VideoPlayer}
 * @param controls - Whether to show the controls. Defaults to false.
 * @param style - The style of the video view - {@link ViewStyle}
 * @param pictureInPicture - Whether to show the picture in picture button. Defaults to false.
 * @param autoEnterPictureInPicture - Whether to automatically enter picture in picture mode
 * when the video is playing. Defaults to false.
 * @param resizeMode - How the video should be resized to fit the view. Defaults to 'none'.
 * @param autoplay - Whether to automatically start playing the video when loaded. Defaults to true.
 * @param fullscreen - Whether the video should be displayed in fullscreen mode. Defaults to false.
 */
const VideoView = React.forwardRef<VideoViewRef, VideoViewProps>(
  (
    {
      player,
      controls = false,
      pictureInPicture = false,
      autoEnterPictureInPicture = false,
      resizeMode = 'none',
      autoplay = true,
      fullscreen = false,
      paused,
      speed,
      showLoadingIndicator = false,
      loadingIndicatorColor,
      onPictureInPictureChange,
      onFullscreenChange,
      willEnterFullscreen,
      willExitFullscreen,
      willEnterPictureInPicture,
      willExitPictureInPicture,
      ...props
    },
    ref
  ) => {
    const nitroId = React.useMemo(() => nitroIdCounter++, []);
    const nitroViewManager = React.useRef<VideoViewViewManager | null>(null);
    const [isManagerReady, setIsManagerReady] = React.useState(false);

    const [hasLoadedMedia, setHasLoadedMedia] = React.useState(false);
    const [isBuffering, setIsBuffering] = React.useState(false);
    const [playerStatus, setPlayerStatus] = React.useState<VideoPlayerStatus>(
      player.status
    );

    React.useEffect(() => {
      if (!showLoadingIndicator) {
        return;
      }
      setPlayerStatus(player.status);
      setHasLoadedMedia(player.status === 'readyToPlay');
      const onLoadStart = () => {
        setHasLoadedMedia(false);
        setIsBuffering(true);
      };
      const onLoad = () => {
        setHasLoadedMedia(true);
        setIsBuffering(false);
      };
      const onBuffer = (buffering: boolean) => setIsBuffering(buffering);
      const onStatus = (status: VideoPlayerStatus) => setPlayerStatus(status);

      const subLoadStart = player.addEventListener('onLoadStart', onLoadStart);
      const subLoad = player.addEventListener('onLoad', onLoad);
      const subBuffer = player.addEventListener('onBuffer', onBuffer);
      const subStatus = player.addEventListener('onStatusChange', onStatus);

      return () => {
        subLoadStart.remove();
        subLoad.remove();
        subBuffer.remove();
        subStatus.remove();
      };
    }, [player, showLoadingIndicator]);

    const showNativeSpinner =
      showLoadingIndicator &&
      playerStatus !== 'error' &&
      playerStatus !== 'idle' &&
      (!hasLoadedMedia || isBuffering);

    const setupViewManager = React.useCallback(
      (id: number) => {
        try {
          if (nitroViewManager.current === null) {
            nitroViewManager.current =
              VideoViewViewManagerFactory.createViewManager(id);

            // Should never happen
            if (!nitroViewManager.current) {
              throw new VideoError(
                'view/not-found',
                'Failed to create View Manager'
              );
            }
          }

          setIsManagerReady(true);
        } catch (error) {
          const parsedError = tryParseNativeVideoError(error);

          if (
            parsedError instanceof VideoComponentError &&
            parsedError.code === 'view/not-found'
          ) {
            // The view was not found, did view get unmounted?
            if (id === nitroId) {
              // The id from native is same as the one we have,
              // so the view was unmounted before native manager was able to find it

              // On slow devices, when we quickly mount and unmount the view,
              // the native manager may not have been able to find the view before the view was unmounted
              // This should really never happen, but it's better to be safe than sorry

              // We don't throw an error here, because it's not an actual error.
              console.warn(
                '[Unified Player] VideoView was unmounted before native manager was able to find it. It can happen when the view is quickly mounted and unmounted.'
              );

              return;
            }
          }

          throw parsedError;
        }
      },
      [nitroId]
    );

    const onNitroIdChange = React.useCallback(
      (event: { nativeEvent: { nitroId: number } }) => {
        setupViewManager(event.nativeEvent.nitroId);
      },
      [setupViewManager]
    );

    React.useImperativeHandle(
      ref,
      () => ({
        enterFullscreen: () => {
          wrapNativeViewManagerFunction(nitroViewManager.current, (manager) => {
            manager.enterFullscreen();
          });
        },
        exitFullscreen: () => {
          wrapNativeViewManagerFunction(nitroViewManager.current, (manager) => {
            manager.exitFullscreen();
          });
        },
        enterPictureInPicture: () => {
          wrapNativeViewManagerFunction(nitroViewManager.current, (manager) => {
            manager.enterPictureInPicture();
          });
        },
        exitPictureInPicture: () => {
          wrapNativeViewManagerFunction(nitroViewManager.current, (manager) => {
            manager.exitPictureInPicture();
          });
        },
        canEnterPictureInPicture: () => {
          return wrapNativeViewManagerFunction(
            nitroViewManager.current,
            (manager) => {
              return manager.canEnterPictureInPicture();
            }
          );
        },
        addEventListener: <Event extends keyof VideoViewEvents>(
          event: Event,
          callback: VideoViewEvents[Event]
        ): ListenerSubscription => {
          return wrapNativeViewManagerFunction(
            nitroViewManager.current,
            (manager) => {
              switch (event) {
                case 'onPictureInPictureChange':
                  return manager.addOnPictureInPictureChangeListener(
                    callback as VideoViewEvents['onPictureInPictureChange']
                  );
                case 'onFullscreenChange':
                  return manager.addOnFullscreenChangeListener(
                    callback as VideoViewEvents['onFullscreenChange']
                  );
                case 'willEnterFullscreen':
                  return manager.addWillEnterFullscreenListener(
                    callback as VideoViewEvents['willEnterFullscreen']
                  );
                case 'willExitFullscreen':
                  return manager.addWillExitFullscreenListener(
                    callback as VideoViewEvents['willExitFullscreen']
                  );
                case 'willEnterPictureInPicture':
                  return manager.addWillEnterPictureInPictureListener(
                    callback as VideoViewEvents['willEnterPictureInPicture']
                  );
                case 'willExitPictureInPicture':
                  return manager.addWillExitPictureInPictureListener(
                    callback as VideoViewEvents['willExitPictureInPicture']
                  );
                default:
                  throw new Error(
                    `[Unified Player] Unsupported event: ${event}`
                  );
              }
            }
          );
        },
      }),
      []
    );

    // When the view unmounts (e.g. user left the screen), pause unless background playback is enabled.
    React.useEffect(() => {
      return () => {
        try {
          if (!player.playInBackground) {
            player.pause();
          }
        } catch {
          // Player may already be released if parent teardown order differs.
        }
      };
    }, [player]);

    // Cleanup all listeners on unmount
    React.useEffect(() => {
      return () => {
        if (nitroViewManager.current) {
          nitroViewManager.current.clearAllListeners();
          setIsManagerReady(false);
        }
      };
    }, []);

    // Register prop-based event callbacks as listeners
    React.useEffect(() => {
      if (!nitroViewManager.current) {
        return;
      }

      const subscriptions: ListenerSubscription[] = [];

      if (onPictureInPictureChange) {
        subscriptions.push(
          nitroViewManager.current.addOnPictureInPictureChangeListener(
            onPictureInPictureChange
          )
        );
      }
      if (onFullscreenChange) {
        subscriptions.push(
          nitroViewManager.current.addOnFullscreenChangeListener(
            onFullscreenChange
          )
        );
      }
      if (willEnterFullscreen) {
        subscriptions.push(
          nitroViewManager.current.addWillEnterFullscreenListener(
            willEnterFullscreen
          )
        );
      }
      if (willExitFullscreen) {
        subscriptions.push(
          nitroViewManager.current.addWillExitFullscreenListener(
            willExitFullscreen
          )
        );
      }
      if (willEnterPictureInPicture) {
        subscriptions.push(
          nitroViewManager.current.addWillEnterPictureInPictureListener(
            willEnterPictureInPicture
          )
        );
      }
      if (willExitPictureInPicture) {
        subscriptions.push(
          nitroViewManager.current.addWillExitPictureInPictureListener(
            willExitPictureInPicture
          )
        );
      }

      return () => {
        subscriptions.forEach((sub) => sub.remove());
      };
    }, [
      onPictureInPictureChange,
      onFullscreenChange,
      willEnterFullscreen,
      willExitFullscreen,
      willEnterPictureInPicture,
      willExitPictureInPicture,
      isManagerReady,
    ]);

    // Update non-event props
    React.useEffect(() => {
      if (!nitroViewManager.current) {
        return;
      }

      // Update props to native view
      updateProps(nitroViewManager.current, {
        ...props,
        player: player,
        controls: controls,
        pictureInPicture: pictureInPicture,
        autoEnterPictureInPicture: autoEnterPictureInPicture,
        resizeMode: resizeMode,
      });
    }, [
      player,
      controls,
      pictureInPicture,
      autoEnterPictureInPicture,
      resizeMode,
      props,
      isManagerReady,
    ]);

    // Handle paused prop changes
    React.useEffect(() => {
      if (paused === undefined) return;

      if (paused) {
        player.pause();
      } else {
        player.play();
      }
    }, [paused, player]);

    // Handle speed prop changes
    React.useEffect(() => {
      if (speed === undefined) return;

      player.rate = speed;
    }, [speed, player]);

    // Handle autoplay when the view manager is ready
    const hasAutoplayedRef = React.useRef(false);
    React.useEffect(() => {
      // If paused is explicitly set to true, we shouldn't autoplay
      if (paused) return;

      if (isManagerReady && autoplay && !hasAutoplayedRef.current) {
        hasAutoplayedRef.current = true;
        player.play();
      }
    }, [isManagerReady, autoplay, player, paused]);

    // Handle fullscreen prop changes — only act on real transitions.
    // Initial mount must not call exit/enterFullscreen: the underlying
    // native view may already be deallocated in recycler scenarios
    // (e.g. FlatList/FlashList items mounted/unmounted rapidly).
    const prevFullscreenRef = React.useRef<boolean | undefined>(undefined);
    React.useEffect(() => {
      if (!nitroViewManager.current || !isManagerReady) {
        return;
      }

      const prev = prevFullscreenRef.current;
      prevFullscreenRef.current = fullscreen;

      if (prev === undefined || prev === fullscreen) {
        return;
      }

      try {
        if (fullscreen) {
          nitroViewManager.current.enterFullscreen();
        } else {
          nitroViewManager.current.exitFullscreen();
        }
      } catch (error) {
        console.warn(
          '[UnifiedPlayer] Failed to change fullscreen state:',
          error
        );
      }
    }, [fullscreen, isManagerReady]);

    if (!showLoadingIndicator) {
      return (
        <NativeVideoView
          nitroId={nitroId}
          onNitroIdChange={onNitroIdChange}
          {...props}
        />
      );
    }

    return (
      <View style={props.style} collapsable={false}>
        <NativeVideoView
          nitroId={nitroId}
          onNitroIdChange={onNitroIdChange}
          {...props}
          style={StyleSheet.absoluteFill}
        />
        {showNativeSpinner ? (
          <View style={styles.loadingOverlay} pointerEvents="none">
            <ActivityIndicator size="large" color={loadingIndicatorColor} />
          </View>
        ) : null}
      </View>
    );
  }
);

const styles = StyleSheet.create({
  loadingOverlay: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center',
    justifyContent: 'center',
  },
});

VideoView.displayName = 'VideoView';

export default React.memo(VideoView);
