import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
// The page reads its stats through `provider`, which the app uses but does not
// list as a direct dependency (pre-existing; see the same info on `lib`).
// ignore: depend_on_referenced_packages
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';
import 'package:tvninja/services/video/unified_video_player.dart';

/// An mpv player that does nothing: a real one cannot be built on the test
/// host (no libmpv), and these tests are about what the page does around it.
class _FakePlayer extends Fake implements mk.Player {
  @override
  Future<void> open(mk.Playable playable,
          {bool play = true, Map<String, dynamic>? extras}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  mk.PlayerStream get stream => _FakePlayerStream();
}

class _FakePlayerStream extends Fake implements mk.PlayerStream {
  @override
  Stream<bool> get playing => const Stream<bool>.empty();
  @override
  Stream<bool> get buffering => const Stream<bool>.empty();
  @override
  Stream<bool> get completed => const Stream<bool>.empty();
  // The audio service's stall detection listens to the position.
  @override
  Stream<Duration> get position => const Stream<Duration>.empty();
  @override
  Stream<String> get error => const Stream<String>.empty();
}

/// Drives the real `PlayerPage` in the sound mode the person chose with the
/// AppBar toggle, and delivers the notification's Stop the way the native
/// side does: a `stopRequested` event on the audio event channel, which
/// `NativeAudioService` turns into a `PlaybackControl.stop` on its control
/// stream and the page's own listener acts on.
///
/// Stop means stop: the sound ends and the page stays on the sound screen,
/// stopped -- it must not switch to video (which would start the picture
/// playing) behind the person's back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const audioEvents = EventChannel('io.github.giuig.tvninja/audio_events');
  late List<String> audioCalls;
  MockStreamHandlerEventSink? nativeEvents;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
    audioCalls = [];
    nativeEvents = null;
    NativeAudioService.playerFactory = () => _FakePlayer();

    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.giuig.tvninja/pip'), (call) async => null);
    for (final events in ['pip_events', 'noisy_events']) {
      messenger.setMockMethodCallHandler(
          MethodChannel('io.github.giuig.tvninja/$events'),
          (call) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.giuig.tvninja/audio'), (call) async {
      audioCalls.add(call.method);
      return null;
    });
    // `setMockStreamHandler` lives on the messenger itself, not on the
    // channel: it keeps the sink so the test can push native events.
    messenger.setMockStreamHandler(
        audioEvents,
        MockStreamHandler.inline(onListen: (arguments, events) {
          nativeEvents = events;
        }));
    for (final name in ['toggle', 'isEnabled']) {
      messenger.setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.$name',
          (message) async => const StandardMessageCodec()
              .encodeMessage(<Object?>[name == 'isEnabled' ? false : null]));
    }
  });

  tearDown(() async {
    await NativeAudioService.dispose();
    NativeAudioService.playerFactory = mk.Player.new;
    messenger.setMockStreamHandler(audioEvents, null);
  });

  /// Lets the page's chain of platform-channel round trips finish. They run
  /// partly in the fake-async zone (the test body's own calls) and partly on
  /// real time (the stubbed channels' replies), so it alternates the two.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
    }
    await tester.pump();
  }

  /// Opens a video channel (verdict cached, so it is resolved straight away)
  /// and switches it to sound with the AppBar headphones toggle.
  Future<void> openInManualSoundMode(WidgetTester tester) async {
    final channel =
        Channel(name: 'tv', url: 'http://127.0.0.1:1/tv.m3u8');
    StreamKindCache.put(
        channel.uniqueId,
        const StreamKindVerdict(
            StreamKind.video, KindConfidence.strong, KindSource.hlsMasterCodecs));
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppStatsNotifier(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerPage(channel: channel),
      ),
    ));
    await settle(tester);

    await tester.tap(find.byIcon(Icons.headphones));
    await settle(tester);

    // Sound is really running: the service was started and the page offers the
    // way back to video.
    expect(audioCalls, contains('startBackground'));
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(find.byType(UnifiedVideoPlayer), findsNothing);
    expect(nativeEvents, isNotNull,
        reason: 'the page is listening for the notification buttons');
  }

  Future<void> pressNotificationStop(WidgetTester tester) async {
    nativeEvents!.success(<String, dynamic>{'event': 'stopRequested'});
    await settle(tester);
  }

  testWidgets(
      'notification Stop in manual sound mode ends the sound and stays on the '
      'sound screen, without starting the video', (tester) async {
    await openInManualSoundMode(tester);

    await pressNotificationStop(tester);

    expect(audioCalls, contains('stopBackground'),
        reason: 'the sound and its notification are gone');
    // Still on the sound screen: the toggle still offers "back to video" and
    // no video player was mounted -- mounting one is what starts the picture
    // (it autoplays), which is the "Stop starts the video" behaviour.
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(find.byType(UnifiedVideoPlayer), findsNothing,
        reason: 'Stop must not start the video');
    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget,
        reason: 'stopped: the play button is what restarts the sound');
  });

  testWidgets('after Stop the play button restarts the sound for the channel',
      (tester) async {
    await openInManualSoundMode(tester);
    await pressNotificationStop(tester);
    audioCalls.clear();

    await tester.tap(find.byIcon(Icons.play_circle_filled));
    await settle(tester);

    expect(audioCalls, contains('startBackground'));
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(find.byType(UnifiedVideoPlayer), findsNothing);
  });

  testWidgets('after Stop the headphones toggle still goes back to video',
      (tester) async {
    await openInManualSoundMode(tester);
    await pressNotificationStop(tester);

    await tester.tap(find.byIcon(Icons.videocam));
    // One frame, not `settle`: the stubbed stream makes the video engine fail
    // a moment after it mounts, and the error screen replaces the player.
    await tester.pump();

    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
    expect(find.byIcon(Icons.headphones), findsOneWidget);
  });
}
