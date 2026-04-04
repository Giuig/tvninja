import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PipService {
  static const MethodChannel _methodChannel =
      MethodChannel('io.github.giuig.tvninja/pip');
  static const EventChannel _eventChannel =
      EventChannel('io.github.giuig.tvninja/pip_events');

  static Stream<bool>? _pipStateStream;
  static bool _isInPipMode = false;

  static Future<bool> isSupported() async {
    if (kIsWeb) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('isPipSupported');
      return result ?? false;
    } catch (e) {
      debugPrint('PiP support check failed: $e');
      return false;
    }
  }

  static Future<bool> enterPip() async {
    if (kIsWeb) return false;
    try {
      final result =
          await _methodChannel.invokeMethod<bool>('enterPictureInPicture');
      return result ?? false;
    } catch (e) {
      debugPrint('Enter PiP failed: $e');
      return false;
    }
  }

  static Future<void> setFullscreenVideoMode(bool isFullscreen) async {
    if (kIsWeb) return;
    try {
      await _methodChannel.invokeMethod('setFullscreenVideoMode', isFullscreen);
    } catch (e) {
      debugPrint('setFullscreenVideoMode failed: $e');
    }
  }

  static Stream<bool> get pipStateStream {
    _pipStateStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => event as bool)
        .handleError((error) {
      debugPrint('PiP stream error: $error');
    });
    return _pipStateStream!;
  }

  static bool get isInPipMode => _isInPipMode;

  static void setPipMode(bool isInPip) {
    _isInPipMode = isInPip;
  }
}
