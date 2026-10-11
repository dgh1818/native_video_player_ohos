import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_video_player/native_video_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pluginChannel = MethodChannel('me.albemala.native_video_player.plugin');
  const playerChannel = MethodChannel('me.albemala.native_video_player.api.42');

  setUp(() {
    messenger
      ..setMockMethodCallHandler(pluginChannel, (_) async => 42)
      ..setMockMethodCallHandler(playerChannel, (_) async => null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger
      ..setMockMethodCallHandler(pluginChannel, null)
      ..setMockMethodCallHandler(playerChannel, null);
  });

  test('OHOS paused seek keeps the native position', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
    final controller = await NativeVideoPlayerController.createOhos();
    controller.onPlaybackStatusChanged.value = PlaybackStatus.paused;
    controller.onPlaybackPositionChanged.value = 2000;

    await controller.seekTo(0);

    expect(controller.playbackInfo?.position, 2000);
  });

  test('other platforms retain the paused seek position update', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = await NativeVideoPlayerController.createOhos();
    controller.onPlaybackStatusChanged.value = PlaybackStatus.paused;
    controller.onPlaybackPositionChanged.value = 2000;

    await controller.seekTo(0);

    expect(controller.playbackInfo?.position, 0);
  });
}
