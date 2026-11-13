// A pending video reconnect chain must not outlive the switch to sound mode, on the
// emulator (found 2026-11-13 by the round-2 gatekeeper of the reconnect change).
//
// The hole: `UnifiedVideoPlayerState.stop()` (what the player page calls when the user
// switches to audio-only) superseded only the attempt that was in flight. The reconnect
// chain re-arms itself after every attempt, so about 4 s later a new video engine came up
// behind the sound screen.
//
// The test mounts the real player (ExoPlayer on the emulator) on a channel that is gone:
// scripts/ci/loop_stream.py answers /dead with a 404, so the load fails and the chain of
// retries (2 s, 4 s, 8 s ...) starts. Once the first retry has run, the test calls
// `stop()` the way the page does, keeps the player mounted (the shape of the gatekeeper's
// reproduction), starts sound mode on the stand-in station, and then holds for a while
// with the page pumping. It logs the markers below; scripts/ci/e2e_hook.sh does the
// Android side: no `ExoPlayerImpl: Init` after the stop, exactly one OpenSL ES player and
// no AudioTrack, a playing media session and the sound mode's service.
//
// The test also checks itself: the chain's attempt counter must not move after the stop
// (an attempt that fires bumps it). That assertion runs last, after the markers, so the
// hook has seen the evidence even when it fails.
//
// Why the player stays mounted: in the app the same `setState` that switches to the sound
// screen also removes the player from the tree, and its dispose resets the chain. This test
// pins `stop()` itself, which is the call that used to leave the chain alive.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/video/unified_video_player.dart';

// 10.0.2.2 is the emulator's alias for the runner's loopback; the shared runner starts
// scripts/ci/loop_stream.py there (local-stream: true). Overridable like the other tests.
const _deadUrl = String.fromEnvironment('E2E_DEAD_URL',
    defaultValue: 'http://10.0.2.2:8099/dead');
const _streamUrl = String.fromEnvironment('E2E_STREAM_URL',
    defaultValue: 'http://10.0.2.2:8099/stream');

// How long the page keeps pumping after sound mode is playing. The chain's steps after
// the first retry are 4 s and 8 s, so this is more than enough for two more attempts.
const _hold = Duration(seconds: 16);

void main() {
  // An unthrottled debugPrint, so the marker lines reach the test output without a lag.
  debugPrint = debugPrintSynchronously;
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stop() for sound mode ends a pending video reconnect chain',
      timeout: const Timeout(Duration(minutes: 5)), (tester) async {
    MediaKit.ensureInitialized();
    await NativeAudioService.initialize();

    final key = GlobalKey<UnifiedVideoPlayerState>();
    final errors = <String?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UnifiedVideoPlayer(key: key, url: _deadUrl, onError: errors.add),
      ),
    ));

    // Wait until the chain has run its first retry: it has started, a second engine
    // existed, and the next step is pending.
    final chainEnd = DateTime.now().add(const Duration(seconds: 45));
    while (key.currentState!.reconnectAttempt < 1 &&
        DateTime.now().isBefore(chainEnd)) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final attemptAtStop = key.currentState!.reconnectAttempt;
    if (attemptAtStop < 1) {
      debugPrint('E2E_RECON_NO_CHAIN url=$_deadUrl');
      fail('no reconnect chain started on $_deadUrl (attempt=$attemptAtStop)');
    }

    // What the player page does when the user switches to sound mode.
    await key.currentState!.stop();
    final stopMs = DateTime.now().millisecondsSinceEpoch;
    debugPrint('E2E_RECON_STOPPED attempt=$attemptAtStop ms=$stopMs');

    Object? failure;
    try {
      final started = await NativeAudioService.play(
        url: _streamUrl,
        title: 'CI local stream',
      );
      expect(started, isTrue, reason: 'NativeAudioService.play returned false');
      final playEnd = DateTime.now().add(const Duration(seconds: 45));
      while (!(NativeAudioService.currentState.isPlaying &&
          !NativeAudioService.isBuffering)) {
        if (DateTime.now().isAfter(playEnd)) {
          fail('mpv never reported playing on $_streamUrl');
        }
        await tester.pump(const Duration(milliseconds: 250));
      }
      debugPrint('E2E_RECON_SOUND_PLAYING');

      final until = DateTime.now().add(_hold);
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final attemptAfter = key.currentState!.reconnectAttempt;
      debugPrint('E2E_RECON_HOLD_DONE attemptAtStop=$attemptAtStop '
          'attemptAfter=$attemptAfter errors=${errors.length}');
      // The hook reads Android's state now, while the sound is still playing.
      await tester.pump(const Duration(seconds: 12));

      expect(attemptAfter, attemptAtStop,
          reason:
              'a reconnect attempt fired after stop(): the chain outlived the '
              'switch to sound mode');
    } catch (e) {
      failure = e;
      rethrow;
    } finally {
      await NativeAudioService.stop();
      debugPrint('E2E_RECON_DONE failed=${failure != null}');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
