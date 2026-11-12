// Sound mode (background audio) on the emulator, against scripts/ci/loop_stream.py
// running on the runner (reached as 10.0.2.2:8099).
//
// The test starts sound mode through NativeAudioService.play, the call the player page
// makes, waits until mpv reports playing, logs E2E_SOUND_PLAYING and keeps playing for a
// while. scripts/ci/e2e_hook.sh runs alongside: it waits for that marker, then looks at
// what Android shows for the app (the media session and its Stop, the notification) and
// records the audio dumps. It may press Stop in the notification shade; when the Stop
// reaches the app it arrives on NativeAudioService.controlStream, and this test then
// stops the service the way the player page does. The test passes either way.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvninja/services/native_audio_service.dart';

// 10.0.2.2 is the emulator's alias for the runner's loopback. Overridable for a local
// device: --dart-define=E2E_STREAM_URL=http://127.0.0.1:8099/stream with `adb reverse`.
const _streamUrl = String.fromEnvironment('E2E_STREAM_URL',
    defaultValue: 'http://10.0.2.2:8099/stream');
const _hold = Duration(seconds: 30);

void main() {
  // An unthrottled debugPrint, so the marker lines reach logcat without a lag behind the
  // test (the default one throttles to 12 kB per second).
  debugPrint = debugPrintSynchronously;
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // A plain test, not testWidgets: the hook may open the notification shade through
  // uiautomator, which switches Android accessibility on, and the widget tester then fails
  // any test that ends with a semantics handle it did not create. Nothing here needs a
  // widget tree.
  test('sound mode plays, holds, and stops',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    MediaKit.ensureInitialized();
    await NativeAudioService.initialize();

    var stopRequested = false;
    final controlSub = NativeAudioService.controlStream.listen((control) {
      if (control != PlaybackControl.stop) return;
      stopRequested = true;
      debugPrint('E2E_STOP_REQUESTED');
      // What the player page does for a Stop from the notification.
      unawaited(NativeAudioService.stop());
    });

    try {
      final started = await NativeAudioService.play(
        url: _streamUrl,
        title: 'CI local stream',
      );
      expect(started, isTrue, reason: 'NativeAudioService.play returned false');

      await _waitFor(
        () =>
            NativeAudioService.currentState.isPlaying &&
            !NativeAudioService.isBuffering,
        const Duration(seconds: 45),
        'mpv never reported playing on $_streamUrl',
      );

      // Let the native side catch up with the state change before the marker.
      await Future<void>.delayed(const Duration(seconds: 2));
      debugPrint('E2E_SOUND_PLAYING');

      final until = DateTime.now().add(_hold);
      while (DateTime.now().isBefore(until) && !stopRequested) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      debugPrint('E2E_HOLD_OVER stopRequested=$stopRequested');

      if (!stopRequested) {
        expect(await NativeAudioService.stop(), isTrue);
      } else {
        // The Stop was already handled above; give it a moment to finish.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(NativeAudioService.currentState.isPlaying, isFalse);
      expect(NativeAudioService.currentUrl, isNull);
    } finally {
      await controlSub.cancel();
    }
  });
}

Future<void> _waitFor(
    bool Function() condition, Duration timeout, String failure) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail(failure);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}
