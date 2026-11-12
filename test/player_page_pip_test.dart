import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The page reads its stats through `provider`, which the app uses but does not
// list as a direct dependency (pre-existing; see the same info on `lib`).
// ignore: depend_on_referenced_packages
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';

/// Drives the real `PlayerPage` and records what it tells the native side
/// about picture-in-picture eligibility (`setFullscreenVideoMode`), which is
/// what Android's `onUserLeaveHint` consults when Home is pressed.
///
/// The page is mounted on the test host with every platform channel it
/// touches answered by a stub, so the engine underneath never plays anything
/// (it errors out a moment after mounting, which clears eligibility again);
/// what these tests look at is the eligibility the page asked for *at the
/// moment the channel's mode was decided*, i.e. that `true` was sent at all.
///
/// The stream-kind probe runs for real: under the widget-test binding every
/// HTTP request answers 400, which the probe reads as "no evidence", i.e. the
/// unknown verdict -- the same video branch a timed-out probe or a plain video
/// verdict takes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pipCalls = <Object?>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
    pipCalls.clear();

    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.giuig.tvninja/pip'), (call) async {
      if (call.method == 'setFullscreenVideoMode') pipCalls.add(call.arguments);
      return null;
    });
    for (final events in ['pip_events', 'noisy_events', 'audio_events']) {
      messenger.setMockMethodCallHandler(
          MethodChannel('io.github.giuig.tvninja/$events'),
          (call) async => null);
    }
    for (final name in ['toggle', 'isEnabled']) {
      messenger.setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.$name',
          (message) async => const StandardMessageCodec()
              .encodeMessage(<Object?>[name == 'isEnabled' ? false : null]));
    }
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.giuig.tvninja/pip'), null);
  });

  Future<void> openPlayer(WidgetTester tester, Channel channel) async {
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppStatsNotifier(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerPage(channel: channel),
      ),
    ));
  }

  Channel channel(String name) =>
      Channel(name: name, url: 'http://127.0.0.1:1/$name.m3u8');

  testWidgets(
      'a video channel opened on a stream-kind cache miss becomes PiP-eligible '
      'once the probe decides it is video', (tester) async {
    await openPlayer(tester, channel('miss'));

    // The probe is real I/O (a refused connection answered by the test
    // binding), so it has to run outside the fake-async zone.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(pipCalls, containsAllInOrder([false, true]),
        reason: 'not eligible while unresolved, eligible once decided; after '
            'the video verdict nothing re-enabled PiP, so Home '
            'never entered picture-in-picture for this open');
  });

  testWidgets('a cache hit is PiP-eligible from the first sync',
      (tester) async {
    final hit = channel('hit');
    StreamKindCache.put(
        hit.uniqueId,
        const StreamKindVerdict(
            StreamKind.video, KindConfidence.strong, KindSource.hlsMasterCodecs));

    await openPlayer(tester, hit);

    expect(pipCalls, contains(true));
  });

  testWidgets(
      'zapping to a channel that needs a probe ends PiP-eligible, not just '
      'unresolved', (tester) async {
    final first = channel('first');
    final second = channel('second');
    StreamKindCache.put(
        first.uniqueId,
        const StreamKindVerdict(
            StreamKind.video, KindConfidence.strong, KindSource.hlsMasterCodecs));

    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppStatsNotifier(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerPage(
            channel: first, channels: [first, second], initialIndex: 0),
      ),
    ));
    // Let the first channel's own start-up noise (platform messages are
    // delivered asynchronously) finish before looking at the zap.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    pipCalls.clear();

    await tester.tap(find.byIcon(Icons.skip_next).first);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(pipCalls, containsAllInOrder([false, true]),
        reason: 'ineligible while the target is probed, eligible once it is '
            'decided to be video');
  });
}
