import {
  AbilityAware,
  AbilityPluginBinding,
  BinaryMessenger,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { TextureRegistry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';
import { NativeVideoPlayerViewController } from './NativeVideoPlayerViewController';

const TAG: string = 'NativeVideoPlayerPlugin';
const PLUGIN_CHANNEL_NAME = 'me.albemala.native_video_player.plugin';

export class NativeVideoPlayerPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private flutterState: FlutterState | null = null;
  private pluginChannel: MethodChannel | null = null;
  private players: Map<number, NativeVideoPlayerViewController> = new Map();

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.flutterState = new FlutterState(
      binding.getBinaryMessenger(),
      binding.getTextureRegistry()
    );
    this.pluginChannel = new MethodChannel(
      binding.getBinaryMessenger(),
      PLUGIN_CHANNEL_NAME
    );
    this.pluginChannel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.pluginChannel?.setMethodCallHandler(null);
    this.pluginChannel = null;
    this.disposeAllPlayers();
    this.flutterState = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
  }

  onDetachedFromAbility(): void {
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'create':
        try {
          result.success(this.createPlayer());
        } catch (error) {
          result.error(
            'create_failed',
            error instanceof Error ? error.message : String(error),
            null
          );
        }
        return;
      default:
        result.notImplemented();
        return;
    }
  }

  private createPlayer(): number {
    if (!this.flutterState) {
      throw new Error('Flutter engine is not attached');
    }
    const textureRegistry = this.flutterState.getTextureRegistry();
    const textureId = textureRegistry.getTextureId();
    const textureEntry = textureRegistry.registerTexture(textureId);
    const player = new NativeVideoPlayerViewController(
      this.flutterState.getBinaryMessenger(),
      textureId,
      textureEntry,
      (playerTextureId: number): void => {
        this.disposePlayer(playerTextureId);
      }
    );
    this.players.set(textureId, player);
    return textureId;
  }

  private disposePlayer(textureId: number): void {
    const player = this.players.get(textureId);
    if (!player) {
      return;
    }
    player.destroy();
    this.flutterState?.getTextureRegistry().unregisterTexture(textureId);
    this.players.delete(textureId);
  }

  private disposeAllPlayers(): void {
    const textureIds: number[] = [];
    this.players.forEach((value: NativeVideoPlayerViewController, key: number) => {
      textureIds.push(key);
    });
    textureIds.forEach((textureId: number) => {
      this.disposePlayer(textureId);
    });
  }
}

class FlutterState {
  private binaryMessenger: BinaryMessenger;
  private textureRegistry: TextureRegistry;

  constructor(binaryMessenger: BinaryMessenger, textureRegistry: TextureRegistry) {
    this.binaryMessenger = binaryMessenger;
    this.textureRegistry = textureRegistry;
  }

  getBinaryMessenger(): BinaryMessenger {
    return this.binaryMessenger;
  }

  getTextureRegistry(): TextureRegistry {
    return this.textureRegistry;
  }
}
