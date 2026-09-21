import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import { SurfaceTextureEntry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';
import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { NativeVideoPlayerApi, NativeVideoPlayerApiDelegate } from './NativeVideoPlayerApi';
import { VideoSource } from './VideoSource';
import { VideoSourceType } from './VideoSourceType';
import { VideoInfo } from './VideoInfo';

const FILE_PREFIX = 'file://';
const FD_PREFIX = 'fd://';
const SEEK_DONE_THRESHOLD_MS = 100;
const CONTINUOUS_SEEK_IDLE_TIMEOUT_MS = 250;
const SEEK_COMPLETION_TIMEOUT_MS = 5000;
const NETWORK_PLAYBACK_STRATEGY: media.PlaybackStrategy = {
  // Keep enough data in memory for a stable progressive stream while the
  // separate start threshold below allows playback to begin quickly.
  preferredBufferDuration: 20,
  preferredBufferDurationForPlaying: 1,
  showFirstFrameOnPrepare: true,
};
const SUPPORTED_PLAYBACK_SPEEDS: Map<number, media.PlaybackSpeed> = new Map<number, media.PlaybackSpeed>([
  [0.75, media.PlaybackSpeed.SPEED_FORWARD_0_75_X],
  [1.0, media.PlaybackSpeed.SPEED_FORWARD_1_00_X],
  [1.25, media.PlaybackSpeed.SPEED_FORWARD_1_25_X],
  [1.75, media.PlaybackSpeed.SPEED_FORWARD_1_75_X],
  [2.0, media.PlaybackSpeed.SPEED_FORWARD_2_00_X],
]);

interface PromiseLikeVoid {
  then: (handler: () => void) => void;
  catch?: (handler: (error: Error) => void) => void;
}

function hasThen(value: object): boolean {
  return typeof (value as PromiseLikeVoid).then === 'function';
}

function canSeek(state: media.AVPlayerState): boolean {
  return state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed';
}

function canSetLoop(state: media.AVPlayerState): boolean {
  return canSeek(state);
}

function canPlay(state: media.AVPlayerState): boolean {
  return state === 'prepared' || state === 'paused' || state === 'completed';
}

function canPause(state: media.AVPlayerState): boolean {
  return state === 'playing';
}

interface AVPlayerWithPlaybackRate extends media.AVPlayer {
  setPlaybackRate(rate: number): void;
}

interface PendingSeekCompletion {
  resolve: () => void;
  reject: (error: Error) => void;
}

interface SeekPositionGuard {
  start: number;
  target: number;
}

export class NativeVideoPlayerViewController implements NativeVideoPlayerApiDelegate {
  private api: NativeVideoPlayerApi;
  private player: media.AVPlayer | null = null;
  private readonly textureId: number;
  private readonly surfaceId: string;
  private readonly onReleaseRequested: (textureId: number) => void;
  private pendingSource: VideoSource | null = null;
  private lastPosition: number = -1;
  private loop: boolean = false;
  private isSeeking: boolean = false;
  private pendingSeekPosition: number | null = null;
  private continuousSeekActive: boolean = false;
  private continuousSeekTimer: number | null = null;
  private seekCompletionTimer: number | null = null;
  private continuousSeekSupported: boolean | null = null;
  private fileDescriptor: number | null = null;
  private pendingSeekCompletions: Array<PendingSeekCompletion> = [];
  private seekPositionGuard: SeekPositionGuard | null = null;
  private seekStartPosition: number | null = null;

  private onStateChangeHandler?: (state: media.AVPlayerState, reason: media.StateChangeReason) => Promise<void>;
  private onTimeUpdateHandler?: (time: number) => void;
  private onSeekDoneHandler?: (time: number) => void;
  private onErrorHandler?: (error: BusinessError) => void;

  constructor(
    messenger: BinaryMessenger,
    textureId: number,
    textureEntry: SurfaceTextureEntry,
    onReleaseRequested: (textureId: number) => void
  ) {
    console.info(`NativeVideoPlayerViewController created textureId=${textureId}`);
    this.textureId = textureId;
    this.surfaceId = textureEntry.getSurfaceId().toString();
    this.onReleaseRequested = onReleaseRequested;
    this.api = new NativeVideoPlayerApi(messenger, textureId);
    this.api.delegate = this;
    this.createPlayer();
  }

  destroy(): void {
    this.api.dispose();
    this.releasePlayer();
  }

  release(): void {
    this.onReleaseRequested(this.textureId);
  }

  async loadVideoSource(videoSource: VideoSource): Promise<void> {
    this.pendingSource = videoSource;
    this.clearSeekState();
    this.continuousSeekSupported = null;
    this.lastPosition = -1;
    if (!this.player) {
      return;
    }
    if (this.player.state === 'idle') {
      await this.tryApplyPendingSource();
      return;
    }
    try {
      await this.player.reset();
      await this.tryApplyPendingSource();
    } catch (e) {
      this.api.onError(e);
    }
  }

  getVideoInfo(): VideoInfo {
    const height = this.player?.height ?? 0;
    const width = this.player?.width ?? 0;
    const duration = this.player?.duration ?? 0;
    return new VideoInfo(height, width, duration);
  }

  getPlaybackPosition(): number {
    return this.player?.currentTime ?? 0;
  }

  play(): void {
    const player = this.player;
    if (!player || !canPlay(player.state)) {
      return;
    }
    this.finishContinuousSeek();
    if (player.state === 'completed') {
      this.safeRun(() => player.seek(0, media.SeekMode.SEEK_PREV_SYNC));
    }
    this.safeRunVoid(
      () => player.play(),
      (error: Error | string) => this.api.onError(error)
    );
  }

  pause(): void {
    const player = this.player;
    if (!player) {
      return;
    }
    this.finishContinuousSeek();
    if (!canPause(player.state)) return;
    this.safeRunVoid(
      () => player.pause(),
      (error: Error | string) => this.api.onError(error)
    );
  }

  stop(): void {
    const player = this.player;
    if (!player) return;
    this.finishContinuousSeek();
    this.clearSeekState();
    const state = player.state;
    const seekToStart = (): void => {
      const activePlayer = this.player;
      if (activePlayer && canSeek(activePlayer.state)) {
        this.safeRun(() => activePlayer.seek(0, media.SeekMode.SEEK_PREV_SYNC));
      }
    };
    if (state === 'playing') {
      this.safeRunVoid(
        () => player.pause(),
        (error: Error | string) => this.api.onError(error),
        seekToStart
      );
      return;
    }
    seekToStart();
  }

  isPlaying(): boolean {
    return this.player?.state === 'playing';
  }

  seekTo(position: number): Promise<void> {
    const player = this.player;
    if (!player || !canSeek(player.state)) return Promise.resolve();

    const completion = new Promise<void>((resolve, reject) => {
      this.pendingSeekCompletions.push({ resolve, reject });
    });

    this.isSeeking = true;
    this.seekPositionGuard = null;
    this.seekStartPosition = this.readCurrentPosition(player);
    this.pendingSeekPosition = position;
    if (this.canUseContinuousSeek(player)) {
      this.continuousSeekActive = true;
      this.scheduleContinuousSeekFinish();
      try {
        player.seek(position, media.SeekMode.SEEK_CONTINUOUS);
        return completion;
      } catch (e) {
        // Some codecs/devices report support but still reject the operation.
        // Fall back to the keyframe seek path instead of leaving the player
        // in a permanently seeking state.
        this.continuousSeekActive = false;
        this.cancelContinuousSeekTimer();
        this.continuousSeekSupported = false;
      }
    }

    try {
      player.seek(position, media.SeekMode.SEEK_PREV_SYNC);
      this.scheduleSeekCompletionTimeout();
    } catch (e) {
      const error = this.toError(e);
      this.clearSeekState(error);
      this.api.onError(error);
    }

    return completion;
  }

  setPlaybackSpeed(speed: number): void {
    const player = this.player;
    if (!player || !canSeek(player.state)) {
      return;
    }

    try {
      const playbackRatePlayer = player as AVPlayerWithPlaybackRate;
      if (typeof playbackRatePlayer.setPlaybackRate === 'function') {
        playbackRatePlayer.setPlaybackRate(speed);
        return;
      }

      const playbackSpeed = this.resolvePlaybackSpeed(speed);
      if (playbackSpeed == null) {
        return;
      }
      player.setSpeed(playbackSpeed);
    } catch (e) {
      this.api.onError(e);
    }
  }

  setVolume(volume: number): void {
    const player = this.player;
    if (!player || !canSeek(player.state)) {
      return;
    }
    try {
      player.setVolume(volume);
    } catch (e) {
      this.api.onError(e);
    }
  }

  setLoop(loop: boolean): void {
    this.loop = loop;
    if (this.player && canSetLoop(this.player.state)) {
      this.player.loop = loop;
    }
  }

  private handleMaybePromise(
    result: Promise<void> | void,
    onSuccess?: () => void,
    onError?: (error: Error) => void
  ): void {
    if (result && hasThen(result as object)) {
      const promise = result as PromiseLikeVoid;
      if (onSuccess) {
        promise.then(onSuccess);
      }
      if (onError && typeof promise.catch === 'function') {
        promise.catch(onError);
      }
      return;
    }
    if (onSuccess) {
      onSuccess();
    }
  }

  private safeRun(action: () => void): void {
    try {
      action();
    } catch (e) {
      this.api.onError(e);
    }
  }

  private safeRunVoid(
    action: () => Promise<void> | void,
    onError?: (error: Error | string) => void,
    onSuccess?: () => void
  ): void {
    try {
      const result = action();
      this.handleMaybePromise(
        result,
        onSuccess,
        (error: Error) => {
          if (onError) {
            onError(error);
            return;
          }
          this.api.onError(error);
        }
      );
    } catch (e) {
      if (onError) {
        onError(e instanceof Error ? e : String(e));
        return;
      }
      this.api.onError(e);
    }
  }

  private async createPlayer(): Promise<void> {
    try {
      this.player = await media.createAVPlayer();
      this.attachListeners();
      await this.tryApplyPendingSource();
    } catch (e) {
      this.api.onError(e);
    }
  }

  private attachListeners(): void {
    if (!this.player) return;
    this.onStateChangeHandler = async (
      state: media.AVPlayerState,
      reason: media.StateChangeReason
    ): Promise<void> => {
      if (!this.player) return;
      switch (state) {
        case 'idle':
          await this.tryApplyPendingSource();
          break;
        case 'initialized':
          if (!this.player) return;
          if (this.player.state === 'initialized') {
            this.player.surfaceId = this.surfaceId;
            try {
              const prepareResult = this.player.prepare();
              this.handleMaybePromise(prepareResult, undefined, (error: Error) => {
                this.api.onError(error);
              });
            } catch (e) {
              this.api.onError(e);
            }
          }
          break;
        case 'prepared':
          this.configureVideoScaleType();
          this.player.loop = this.loop;
          this.api.onPlaybackReady();
          break;
        case 'completed':
          if (!this.loop) {
            this.api.onPlaybackEnded();
          }
          break;
        default:
          break;
      }
    };
    this.player.on('stateChange', this.onStateChangeHandler);

    this.player.on(
      'timeUpdate',
      (this.onTimeUpdateHandler = (time: number): void => {
        // A timeUpdate can describe the old position while a seek is still
        // pending. Only seekDone is authoritative for the Flutter state.
        if (this.isSeeking) {
          return;
        }
        if (this.seekPositionGuard != null && !this.isPositionPastSeekGuard(time)) {
          return;
        }
        this.seekPositionGuard = null;
        if (this.lastPosition !== time) {
          this.lastPosition = time;
          this.api.onPlaybackPositionChanged(time);
        }
      })
    );

    this.player.on(
      'seekDone',
      (this.onSeekDoneHandler = (requestedTime: number): void => {
      const player = this.player;
      const pendingPosition = this.pendingSeekPosition;
      if (!player || this.continuousSeekActive || !this.isSeeking || pendingPosition == null) {
        return;
      }

      // A previous seek may complete after a newer slider position was sent.
      // Re-issue the newest target and wait for its completion notification.
      if (Math.abs(requestedTime - pendingPosition) > SEEK_DONE_THRESHOLD_MS) {
        try {
          player.seek(pendingPosition, media.SeekMode.SEEK_PREV_SYNC);
          this.scheduleSeekCompletionTimeout();
        } catch (e) {
          const error = this.toError(e);
          this.clearSeekState(error);
          this.api.onError(error);
        }
        return;
      }

      this.cancelSeekCompletionTimer();
      this.isSeeking = false;
      this.pendingSeekPosition = null;
      // Report the requested position once. The Flutter controller also
      // applies the requested value for paused playback; reporting a nearby
      // keyframe first would make the progress bar visibly bounce.
      this.seekPositionGuard = {
        start: this.seekStartPosition ?? pendingPosition,
        target: pendingPosition,
      };
      this.seekStartPosition = null;
      this.lastPosition = pendingPosition;
      this.api.onPlaybackPositionChanged(pendingPosition);
      this.completePendingSeek();
      })
    );

    this.onErrorHandler = (error: BusinessError): void => {
      this.clearSeekState(this.toError(error.message));
      this.api.onError(error.message);
    };
    this.player.on('error', this.onErrorHandler);
  }

  private resolvePlaybackSpeed(speed: number): media.PlaybackSpeed | null {
    let bestMatch: media.PlaybackSpeed | null = null;
    let bestDelta = Number.MAX_VALUE;

    SUPPORTED_PLAYBACK_SPEEDS.forEach((mappedValue: media.PlaybackSpeed, candidate: number) => {
      const delta = Math.abs(candidate - speed);
      if (delta < bestDelta) {
        bestDelta = delta;
        bestMatch = mappedValue;
      }
    });

    return bestMatch;
  }

  private configureVideoScaleType(): void {
    const player = this.player;
    if (!player) {
      return;
    }

    try {
      // Preserve the video's aspect ratio inside the surface instead of stretching it.
      player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    } catch (e) {
      this.api.onError(e);
    }
  }

  private async tryApplyPendingSource(): Promise<boolean> {
    if (!this.player || !this.pendingSource || this.player.state !== 'idle') {
      return false;
    }
    const source = this.pendingSource;
    this.pendingSource = null;
    try {
      await this.applyVideoSource(source);
      return true;
    } catch (e) {
      this.api.onError(e);
      return false;
    }
  }

  private async applyVideoSource(videoSource: VideoSource): Promise<void> {
    if (!this.player) return;

    this.closeFileDescriptor();
    if (videoSource.type === VideoSourceType.Network) {
      const mediaSource = media.createMediaSourceWithUrl(
        videoSource.path,
        videoSource.headers
      );
      await this.player.setMediaSource(mediaSource, NETWORK_PLAYBACK_STRATEGY);
    } else {
      const sourceUri = this.toFileUri(videoSource.path);
      if (sourceUri.startsWith(FD_PREFIX)) {
        this.player.fdSrc = {
          fd: Number.parseInt(sourceUri.substring(FD_PREFIX.length))
        };
      } else {
        this.player.url = sourceUri;
      }
    }
  }

  private toFileUri(path: string): string {
    if (path.startsWith(FD_PREFIX)) return path;
    let filePath = path;
    if (filePath.startsWith(FILE_PREFIX)) {
      filePath = filePath.substring(FILE_PREFIX.length);
    }

    try {
      const openFile = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      this.fileDescriptor = openFile.fd;
      return `${FD_PREFIX}${openFile.fd}`;
    } catch (e) {
      return filePath.startsWith(FILE_PREFIX) ? filePath : `${FILE_PREFIX}${filePath}`;
    }
  }

  private closeFileDescriptor(): void {
    if (this.fileDescriptor == null) return;
    try {
      fs.closeSync(this.fileDescriptor);
    } catch (e) {
    } finally {
      this.fileDescriptor = null;
    }
  }

  private canUseContinuousSeek(player: media.AVPlayer): boolean {
    if (this.continuousSeekSupported == null) {
      try {
        this.continuousSeekSupported = player.isSeekContinuousSupported();
      } catch (e) {
        this.continuousSeekSupported = false;
      }
    }
    return this.continuousSeekSupported === true;
  }

  private scheduleContinuousSeekFinish(): void {
    this.cancelContinuousSeekTimer();
    this.continuousSeekTimer = setTimeout(() => {
      this.continuousSeekTimer = null;
      this.finishContinuousSeek();
    }, CONTINUOUS_SEEK_IDLE_TIMEOUT_MS);
  }

  private scheduleSeekCompletionTimeout(): void {
    this.cancelSeekCompletionTimer();
    this.seekCompletionTimer = setTimeout(() => {
      this.seekCompletionTimer = null;
      if (!this.isSeeking || this.continuousSeekActive) return;

      const requestedPosition = this.pendingSeekPosition;
      this.isSeeking = false;
      this.pendingSeekPosition = null;
      const reportedPosition = requestedPosition ?? 0;
      this.seekPositionGuard = {
        start: this.seekStartPosition ?? reportedPosition,
        target: reportedPosition,
      };
      this.seekStartPosition = null;
      this.lastPosition = reportedPosition;
      this.api.onPlaybackPositionChanged(reportedPosition);
      this.completePendingSeek();
    }, SEEK_COMPLETION_TIMEOUT_MS);
  }

  private cancelSeekCompletionTimer(): void {
    if (this.seekCompletionTimer == null) return;
    clearTimeout(this.seekCompletionTimer);
    this.seekCompletionTimer = null;
  }

  private completePendingSeek(error?: Error): void {
    const completions = this.pendingSeekCompletions;
    this.pendingSeekCompletions = [];
    completions.forEach((completion: PendingSeekCompletion) => {
      if (error) {
        completion.reject(error);
      } else {
        completion.resolve();
      }
    });
  }

  private toError(error: Error | string): Error {
    return error instanceof Error ? error : new Error(String(error));
  }

  private readCurrentPosition(player: media.AVPlayer): number {
    try {
      return player.currentTime;
    } catch (e) {
      return this.lastPosition >= 0 ? this.lastPosition : 0;
    }
  }

  private isPositionPastSeekGuard(time: number): boolean {
    const guard = this.seekPositionGuard;
    if (guard == null) return true;
    if (guard.target >= guard.start) {
      return time + SEEK_DONE_THRESHOLD_MS >= guard.target;
    }
    return time - SEEK_DONE_THRESHOLD_MS <= guard.target;
  }

  private cancelContinuousSeekTimer(): void {
    if (this.continuousSeekTimer == null) return;
    clearTimeout(this.continuousSeekTimer);
    this.continuousSeekTimer = null;
  }

  private finishContinuousSeek(): void {
    if (!this.continuousSeekActive) return;

    const player = this.player;
    const requestedPosition = this.pendingSeekPosition;
    this.continuousSeekActive = false;
    this.cancelContinuousSeekTimer();

    if (!player || !canSeek(player.state)) {
      this.clearSeekState();
      return;
    }

    try {
      // SEEK_CONTINUOUS deliberately has no seekDone event. Ending the mode
      // commits the last frame and lets us provide the same completion signal
      // to the Flutter side.
      player.seek(-1, media.SeekMode.SEEK_CONTINUOUS);
    } catch (e) {
      this.clearSeekState();
      this.api.onError(e);
      return;
    }

    this.isSeeking = false;
    this.pendingSeekPosition = null;
    const reportedPosition = requestedPosition ?? 0;
    // The player can still deliver timeUpdate events queued before the
    // continuous seek finished. Ignore those until the stream reaches the
    // requested position, otherwise Flutter briefly jumps back to the old
    // playback position after a successful seek.
    this.seekPositionGuard = {
      start: this.seekStartPosition ?? reportedPosition,
      target: reportedPosition,
    };
    this.seekStartPosition = null;
    this.lastPosition = reportedPosition;
    this.api.onPlaybackPositionChanged(reportedPosition);
    this.completePendingSeek();
  }

  private clearSeekState(error?: Error): void {
    this.isSeeking = false;
    this.pendingSeekPosition = null;
    this.continuousSeekActive = false;
    this.seekPositionGuard = null;
    this.seekStartPosition = null;
    this.cancelContinuousSeekTimer();
    this.cancelSeekCompletionTimer();
    this.completePendingSeek(error);
  }

  private releasePlayer(): void {
    this.clearSeekState();
    if (!this.player) {
      this.closeFileDescriptor();
      return;
    }

    if (this.onStateChangeHandler) {
      this.player.off('stateChange', this.onStateChangeHandler);
    }
    if (this.onTimeUpdateHandler) {
      this.player.off('timeUpdate', this.onTimeUpdateHandler);
    }
    if (this.onSeekDoneHandler) {
      this.player.off('seekDone', this.onSeekDoneHandler);
    }
    if (this.onErrorHandler) {
      this.player.off('error', this.onErrorHandler);
    }

    const player = this.player;
    this.player = null;
    this.safeRunVoid(
      () => player.release(),
      undefined,
      () => this.closeFileDescriptor()
    );
    this.closeFileDescriptor();
  }
}
