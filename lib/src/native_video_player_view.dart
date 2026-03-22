import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:native_video_player/src/native_video_player_controller.dart';

/// A [StatefulWidget] that is responsible for displaying a video.
///
/// On iOS, the video is displayed using a combination
/// of AVPlayer and AVPlayerLayer.
///
/// On Android, the video is displayed using a combination
/// of MediaPlayer and VideoView.
///
/// On OHOS, the video is displayed using AVPlayer and XComponent.
class NativeVideoPlayerView extends StatefulWidget {
  final void Function(NativeVideoPlayerController)? onViewReady;

  const NativeVideoPlayerView({
    super.key,
    required this.onViewReady,
  });

  @override
  _NativeVideoPlayerViewState createState() => _NativeVideoPlayerViewState();
}

class _NativeVideoPlayerViewState extends State<NativeVideoPlayerView> {
  NativeVideoPlayerController? _controller;

  void _onOhosPlaybackReady() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.ohos) {
      _createOhosController();
    }
  }

  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.ohos) {
      _controller?.onPlaybackReady.removeListener(_onOhosPlaybackReady);
      _controller?.dispose();
      _controller = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    /// RepaintBoundary is a widget that isolates repaints
    return RepaintBoundary(
      child: _buildNativeView(),
    );
  }

  Future<void> _createOhosController() async {
    try {
      final controller = await NativeVideoPlayerController.createOhos();
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.onPlaybackReady.addListener(_onOhosPlaybackReady);
      _controller = controller;
      setState(() {});
      widget.onViewReady?.call(controller);
    } catch (error) {
      debugPrint('Failed to create OHOS native video player: $error');
    }
  }

  Widget _buildNativeView() {
    const viewType = 'native_video_player_view';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => UiKitView(
          viewType: viewType,
          onPlatformViewCreated: onPlatformViewCreated,
        ),
      TargetPlatform.android => PlatformViewLink(
          viewType: viewType,
          surfaceFactory: (context, controller) {
            return AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers: const <Factory<
                  OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            );
          },
          onCreatePlatformView: (params) {
            return PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: viewType,
              layoutDirection: TextDirection.ltr,
              onFocus: () {
                params.onFocusChanged(true);
              },
            )
              ..addOnPlatformViewCreatedListener(onPlatformViewCreated)
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
          },
        ),
      TargetPlatform.ohos => _buildOhosTextureView(),
      _ => Text('$defaultTargetPlatform is not yet supported by this plugin.')
    };
  }

  Widget _buildOhosTextureView() {
    final textureId = _controller?.textureId;
    if (textureId == null) {
      return const SizedBox.expand();
    }

    final texture = Texture(textureId: textureId);
    final videoInfo = _controller?.videoInfo;
    if (videoInfo == null || videoInfo.width <= 0 || videoInfo.height <= 0) {
      return texture;
    }

    return SizedBox.expand(
      child: FittedBox(
        child: SizedBox(
          width: videoInfo.width.toDouble(),
          height: videoInfo.height.toDouble(),
          child: texture,
        ),
      ),
    );
  }

  /// This method is invoked by the platform view
  /// when the native view is created.
  Future<void> onPlatformViewCreated(int id) async {
    debugPrint('NativeVideoPlayerView onPlatformViewCreated id=$id');
    final controller = NativeVideoPlayerController(id);
    _controller = controller;
    widget.onViewReady?.call(controller);
  }
}
