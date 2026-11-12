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
// It talks to the native channel directly (not through NativeAudioService) so the same
// file can show the failure on the code before the fix.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _audio = MethodChannel('io.github.giuig.tvninja/audio');

// The hook reads the pid and clears the crash buffer once it sees the BEGIN marker; the
// first round waits for that. After the last round the process stays alive so the hook
// can compare its pid and read Android's state while the app is still there.
const _beforeFirstRound = Duration(seconds: 5);
const _betweenRounds = Duration(seconds: 4);
const _afterLastRound = Duration(seconds: 10);
const _rounds = 3;

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
}
