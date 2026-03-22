import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import {MethodChannel,  MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';
import { VideoSource } from './VideoSource';
import { VideoInfo } from './VideoInfo';

export interface NativeVideoPlayerApiDelegate {
  release(): void;
  loadVideoSource(videoSource: VideoSource): Promise<void>;
  getVideoInfo(): VideoInfo;
  getPlaybackPosition(): number;
  play(): void;
  pause(): void;
  stop(): void;
  isPlaying(): boolean;
  seekTo(position: number): void;
  setPlaybackSpeed(speed: number): void;
  setVolume(volume: number): void;
  setLoop(loop: boolean): void;
}

const INVALID_ARGUMENTS_ERROR_CODE = 'invalid_argument';
const INVALID_ARGUMENTS_ERROR_MESSAGE = 'Invalid arguments';

export class NativeVideoPlayerApi implements MethodCallHandler {
  delegate?: NativeVideoPlayerApiDelegate;

  private channel: MethodChannel;

  constructor(messenger: BinaryMessenger, viewId: number) {
    const name = `me.albemala.native_video_player.api.${viewId}`;
    this.channel = new MethodChannel(messenger, name);
    this.channel.setMethodCallHandler(this);
  }

  dispose(): void {
    this.channel.setMethodCallHandler(null);
  }

  onPlaybackReady(): void {
    this.channel.invokeMethod('onPlaybackReady', null);
  }

  onPlaybackEnded(): void {
    this.channel.invokeMethod('onPlaybackEnded', null);
  }

  onPlaybackPositionChanged(position: number): void {
    this.channel.invokeMethod('onPlaybackPositionChanged', position);
  }

  onError(error: Error | string | null): void {
    let message = 'Unknown playback error occurred';
    if (error instanceof Error) {
      message = error.message;
    } else if (error) {
      message = String(error);
    }
    this.channel.invokeMethod('onError', message);
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    switch (call.method) {
      case 'loadVideoSource': {
        const args: Object | undefined = call.args as Object | undefined;
        const videoSource = VideoSource.fromMap(args);
        if (videoSource == undefined) {
          result.error(INVALID_ARGUMENTS_ERROR_CODE, INVALID_ARGUMENTS_ERROR_MESSAGE, null);
          return;
        }
        await this.delegate?.loadVideoSource(videoSource);
        result.success(null);
        return;
      }
      case 'getVideoInfo': {
        const info = this.delegate?.getVideoInfo();
        result.success(info ? info.toMap() : null);
        return;
      }
      case 'getPlaybackPosition': {
        result.success(this.delegate?.getPlaybackPosition());
        return;
      }
      case 'dispose': {
        this.delegate?.release();
        result.success(null);
        return;
      }
      case 'play': {
        this.delegate?.play();
        result.success(null);
        return;
      }
      case 'pause': {
        this.delegate?.pause();
        result.success(null);
        return;
      }
      case 'stop': {
        this.delegate?.stop();
        result.success(null);
        return;
      }
      case 'isPlaying': {
        result.success(this.delegate?.isPlaying());
        return;
      }
      case 'seekTo': {
        const position = call.args as number;
        if (position == null) {
          result.error(INVALID_ARGUMENTS_ERROR_CODE, INVALID_ARGUMENTS_ERROR_MESSAGE, null);
          return;
        }
        this.delegate?.seekTo(position);
        result.success(null);
        return;
      }
      case 'setPlaybackSpeed': {
        const speed = call.args as number;
        if (speed == null) {
          result.error(INVALID_ARGUMENTS_ERROR_CODE, INVALID_ARGUMENTS_ERROR_MESSAGE, null);
          return;
        }
        this.delegate?.setPlaybackSpeed(speed);
        result.success(null);
        return;
      }
      case 'setVolume': {
        const volume = call.args as number;
        if (volume == null) {
          result.error(INVALID_ARGUMENTS_ERROR_CODE, INVALID_ARGUMENTS_ERROR_MESSAGE, null);
          return;
        }
        this.delegate?.setVolume(volume);
        result.success(null);
        return;
      }
      case 'setLoop': {
        const loop = call.args as boolean;
        if (loop == null) {
          result.error(INVALID_ARGUMENTS_ERROR_CODE, INVALID_ARGUMENTS_ERROR_MESSAGE, null);
          return;
        }
        this.delegate?.setLoop(loop);
        result.success(null);
        return;
      }
      default:
        result.notImplemented();
        return;
    }
  }
}
