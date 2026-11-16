// A start of the playback service followed at once by a stop, on the emulator.
//
// Android requires a service started with startForegroundService to call startForeground
// within a few seconds, and kills the app with "Context.startForegroundService() did not
// then call Service.startForeground()" when the service is torn down before it did. A stop
// that arrives right behind a start (a lock-screen handover that is undone straight away,
// or a start that fails a moment after the service was requested) reaches the service in
// exactly that window.
//
// This test sends the two calls the player uses, back to back and without waiting for the
// first to return, so both are queued on the platform thread before the system has had the
// chance to deliver the service's first command. It runs three rounds, then keeps the
// process alive. scripts/ci/e2e_hook.sh runs alongside, takes the app's pid before the
// first round and checks, after the last, that the process is the same, that logcat holds
// no crash and no "did not then call startForeground", and that no playback service,
// session or notification is left.
//
// The first test talks to the native channel directly. The next two go through
// NativeAudioService, the way the player page does: the early foreground start followed at
// once by a stop, and the early start followed by playback and a stop (the service must be
// started once, the session must play, and the stop must end everything).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvninja/services/native_audio_service.dart';

const _audio = MethodChannel('io.github.giuig.tvninja/audio');

// The hook reads the pid and clears the crash buffer once it sees the BEGIN marker; the
// first round waits for that. After the last round the process stays alive so the hook
// can compare its pid and read Android's state while the app is still there.
const _beforeFirstRound = Duration(seconds: 5);
const _betweenRounds = Duration(seconds: 4);
const _afterLastRound = Duration(seconds: 10);
const _rounds = 3;
const _playHold = Duration(seconds: 12);

// The stand-in station of scripts/ci/loop_stream.py on the runner (10.0.2.2 is the
// emulator's alias for its loopback); overridable like sound_mode_test.dart does.
const _streamUrl = String.fromEnvironment('E2E_STREAM_URL',
    defaultValue: 'http://10.0.2.2:8099/stream');

void main() {
  // An unthrottled debugPrint, so the marker lines reach the test output without a lag.
  debugPrint = debugPrintSynchronously;
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // A plain test, not testWidgets: nothing here needs a widget tree, and the hook may
  // switch accessibility on, which testWidgets would then report as a leaked handle.
  test('a service start followed at once by a stop does not crash the app',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    debugPrint('E2E_FGS_RACE_BEGIN');
    await Future<void>.delayed(_beforeFirstRound);

    for (var round = 1; round <= _rounds; round++) {
      // Both calls are issued before either is awaited, so the stop is queued right
      // behind the start.
      final start = _audio.invokeMethod<bool>(
        'startBackground',
        {'title': 'FGS race $round'},
      );
      final stop = _audio.invokeMethod<bool>('stopBackground');
      final results = await Future.wait([start, stop]);
      debugPrint('E2E_FGS_RACE_ROUND $round results=$results');
      expect(results, everyElement(isTrue));
      await Future<void>.delayed(_betweenRounds);
    }

    debugPrint('E2E_FGS_RACE_DONE');
    await Future<void>.delayed(_afterLastRound);
  });

  // The same, through the Dart service the player page uses: the early start, then a stop
  // before the native side has answered. The stop must reach the service in a way that
  // does not crash it, and the early start must report that it was superseded.
  test('an early foreground start followed at once by a stop does not crash',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    debugPrint('E2E_EARLY_RACE_BEGIN');
    for (var round = 1; round <= _rounds; round++) {
      final early =
          NativeAudioService.startForegroundEarly(title: 'Early race $round');
      final stopped = NativeAudioService.stop();
      final results = await Future.wait([early, stopped]);
      debugPrint('E2E_EARLY_RACE_ROUND $round results=$results');
      expect(results, [false, true],
          reason: 'the stop supersedes the start, and the stop succeeds');
      await Future<void>.delayed(_betweenRounds);
    }
    debugPrint('E2E_EARLY_RACE_DONE');
    await Future<void>.delayed(_afterLastRound);
  });

  // The order of a lock handover: the service first, then the stream. The service must be
  // started exactly once (play() does not start it again), the session must be playing,
  // and a stop must end all of it.
  test('an early foreground start, then playback, then a stop',
      timeout: const Timeout(Duration(minutes: 4)), () async {
    MediaKit.ensureInitialized();
    debugPrint('E2E_EARLY_PLAY_BEGIN');
    expect(await NativeAudioService.startForegroundEarly(title: 'Early start'),
        isTrue);
    final started = await NativeAudioService.play(
      url: _streamUrl,
      title: 'CI local stream',
    );
    expect(started, isTrue, reason: 'NativeAudioService.play returned false');

    final end = DateTime.now().add(const Duration(seconds: 45));
    while (!(NativeAudioService.currentState.isPlaying &&
        !NativeAudioService.isBuffering)) {
      if (DateTime.now().isAfter(end)) fail('mpv never reported playing');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    debugPrint('E2E_EARLY_PLAYING');
    await Future<void>.delayed(_playHold);

    expect(await NativeAudioService.stop(), isTrue);
    debugPrint('E2E_EARLY_STOPPED');
    await Future<void>.delayed(_afterLastRound);
  });
}
