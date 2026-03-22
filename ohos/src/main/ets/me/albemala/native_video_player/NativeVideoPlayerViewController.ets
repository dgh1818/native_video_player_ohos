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

function hasHeaders(headers: Record<string, string>): boolean {
  return Object.keys(headers).length > 0;
}

interface AVPlayerWithPlaybackRate extends media.AVPlayer {
  setPlaybackRate(rate: number): void;
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
  private fileDescriptor: number | null = null;

  private onStateChangeHandler?: (state: media.AVPlayerState, reason: media.StateChangeReason) => Promise<void>;
  private onTimeUpdateHandler?: (time: number) => void;
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
    this.isSeeking = false;
    this.pendingSeekPosition = null;
    this.lastPosition = -1;
    if (!this.player) {
      return;
    }
    if (this.player.state === 'idle') {
      this.tryApplyPendingSource();
      return;
    }
    try {
      const resetResult = this.player.reset();
      this.handleMaybePromise(resetResult, undefined, (error: Error) => {
        this.api.onError(error);
      });
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
    if (player.state === 'completed') {
      this.safeRun(() => player.seek(0, media.SeekMode.SEEK_CLOSEST));
    }
    this.safeRunVoid(
      () => player.play(),
      (error: Error | string) => this.api.onError(error)
    );
  }

  pause(): void {
    const player = this.player;
    if (!player || !canPause(player.state)) {
      return;
    }
    this.safeRunVoid(
      () => player.pause(),
      (error: Error | string) => this.api.onError(error)
    );
  }

  stop(): void {
    const player = this.player;
    if (!player) return;
    this.isSeeking = false;
    this.pendingSeekPosition = null;
    const state = player.state;
    const seekToStart = (): void => {
      const activePlayer = this.player;
      if (activePlayer && canSeek(activePlayer.state)) {
        this.safeRun(() => activePlayer.seek(0, media.SeekMode.SEEK_CLOSEST));
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

  seekTo(position: number): void {
    const player = this.player;
    if (!player || !canSeek(player.state)) return;
    this.isSeeking = true;
    this.pendingSeekPosition = position;
    try {
      player.seek(position, media.SeekMode.SEEK_CLOSEST);
      this.isSeeking = false;
      this.pendingSeekPosition = null;
    } catch (e) {
      this.isSeeking = false;
      this.pendingSeekPosition = null;
      this.api.onError(e);
    }
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
      this.tryApplyPendingSource();
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
          this.tryApplyPendingSource();
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
        if (this.isSeeking) {
          if (this.pendingSeekPosition != null) {
            const diff = Math.abs(time - this.pendingSeekPosition);
            if (diff > SEEK_DONE_THRESHOLD_MS) {
              return;
            }
            this.isSeeking = false;
            this.pendingSeekPosition = null;
          } else {
            return;
          }
        }
        if (this.lastPosition !== time) {
          this.lastPosition = time;
          this.api.onPlaybackPositionChanged(time);
        }
      })
    );

    this.onErrorHandler = (error: BusinessError): void => {
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

  private tryApplyPendingSource(): boolean {
    if (!this.player || !this.pendingSource || this.player.state !== 'idle') {
      return false;
    }
    const source = this.pendingSource;
    this.pendingSource = null;
    this.applyVideoSource(source);
    return true;
  }

  private async applyVideoSource(videoSource: VideoSource): Promise<void> {
    if (!this.player) return;

    this.closeFileDescriptor();
    if (videoSource.type === VideoSourceType.Network && hasHeaders(videoSource.headers)) {
      const mediaSource = media.createMediaSourceWithUrl(
        videoSource.path,
        videoSource.headers
      );
      try {
        await this.player.setMediaSource(mediaSource);
      } catch (e) {
        this.api.onError(e);
      }
    } else {
      const sourceUri = videoSource.type === VideoSourceType.Network
        ? videoSource.path
        : this.toFileUri(videoSource.path);
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

  private releasePlayer(): void {
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
