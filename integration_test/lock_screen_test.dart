// A screen lock while a video plays, on the emulator: the stream must carry on as sound
// behind the lock, and the picture must come back on unlock.
//
// The test opens the real player page on a video channel, waits until the picture is
// playing, logs E2E_VIDEO_PLAYING and then only waits. scripts/ci/e2e_hook.sh does the
// rest from outside, the way a person would: it sends the sleep key, looks at what Android
// holds for the app (the media session, the foreground service, the audio players), wakes
// the screen and looks again. The test never touches the page while the app is paused:
// frames are off then, so a pump would never return.
//
// The clip is scripts/ci/serve_fixtures.py serving integration_test/fixtures/lock_clip.mp4
// on the runner (10.0.2.2 is the emulator's alias for its loopback), started by the hook.
// Overridable like the other tests: --dart-define=E2E_VIDEO_URL=...
//
// While the lock is still informational (see the shim), a clip that never starts playing
// ends the test quietly with E2E_VIDEO_FAILED instead of failing it, and the hook reports
// that. Set _strict to turn it into a failure once the check gates.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
// The page reads its stats through `provider`, which the app uses but does not list as a
// direct dependency (pre-existing; the same info is reported on `lib`).
// ignore: depend_on_referenced_packages
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';
import 'package:video_player/video_player.dart';

const _videoUrl = String.fromEnvironment('E2E_VIDEO_URL',
    defaultValue: 'http://10.0.2.2:8098/lock_clip.mp4');

/// false: a clip that never plays ends the test quietly. true: it fails the test.
const _strict = false;

// How long the hook gets to lock and unlock. The test leaves once the screen has come back
// and the hook has had this long to read what Android holds after the unlock.
const _afterUnlock = Duration(seconds: 30);
// The longest the whole lock and unlock may take before the test gives up waiting for them.
const _lockWindow = Duration(seconds: 150);

class _Lifecycle with WidgetsBindingObserver {
  final states = <AppLifecycleState>[];
  bool get sawPaused => states.contains(AppLifecycleState.paused);
  bool get resumedAfterPause {
    final paused = states.indexOf(AppLifecycleState.paused);
    return paused >= 0 &&
        states.sublist(paused).contains(AppLifecycleState.resumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    states.add(state);
    debugPrint('E2E_LIFECYCLE ${DateTime.now().toIso8601String()} $state');
  }
}

void main() {
  // An unthrottled debugPrint, so the marker lines reach the test output without a lag.
  debugPrint = debugPrintSynchronously;
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a video keeps playing as sound behind the lock and returns on unlock',
      timeout: const Timeout(Duration(minutes: 6)), (tester) async {
    MediaKit.ensureInitialized();

    final channel = Channel(name: 'CI lock clip', url: _videoUrl);
    // A known video stream: the page opens straight in video, with no probe of the clip.
    StreamKindCache.put(
        channel.uniqueId,
        const StreamKindVerdict(StreamKind.video, KindConfidence.strong,
            KindSource.contentType));

    final lifecycle = _Lifecycle();
    WidgetsBinding.instance.addObserver(lifecycle);
    try {
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => AppStatsNotifier(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlayerPage(channel: channel),
        ),
      ));

      if (!await _videoIsPlaying(tester)) {
        debugPrint('E2E_VIDEO_FAILED url=$_videoUrl');
        if (_strict) fail('the video never played on $_videoUrl');
        return;
      }
      // Let the native side catch up with the state change before the marker.
      await Future<void>.delayed(const Duration(seconds: 2));
      debugPrint('E2E_VIDEO_PLAYING');

      // From here the hook acts. Nothing below touches the widget tree until the screen
      // is back: while the app is paused no frame is built, and a pump would wait for one.
      final end = DateTime.now().add(_lockWindow);
      while (!lifecycle.resumedAfterPause && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      debugPrint('E2E_LIFECYCLE_SUMMARY sawPaused=${lifecycle.sawPaused} '
          'resumedAfterPause=${lifecycle.resumedAfterPause} '
          'states=${lifecycle.states.map((s) => s.name).join(',')}');

      await Future<void>.delayed(_afterUnlock);
      if (lifecycle.resumedAfterPause) {
        // The page is on screen again, so it may be read. Informational: the hook
        // checks the audio players, this is the picture's own view.
        debugPrint('E2E_VIDEO_AFTER_UNLOCK playing=${_controllerPlaying(tester)}');
      }
      debugPrint('E2E_LOCK_DONE');
      await Future<void>.delayed(const Duration(seconds: 10));
    } finally {
      WidgetsBinding.instance.removeObserver(lifecycle);
    }
  });
}

/// The video controller behind the page, or null while there is none (not mounted yet,
/// or shut down by a lock).
VideoPlayerController? _controller(WidgetTester tester) {
  final finder = find.byType(VideoPlayer);
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<VideoPlayer>(finder.first).controller;
}

bool _controllerPlaying(WidgetTester tester) =>
    _controller(tester)?.value.isPlaying ?? false;

/// Pumps until the clip is playing and has moved past its first second, or 60 s pass.
Future<bool> _videoIsPlaying(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 500));
    final value = _controller(tester)?.value;
    if (value != null &&
        value.isInitialized &&
        value.isPlaying &&
        value.position >= const Duration(seconds: 1)) {
      return true;
    }
  }
  return false;
}
