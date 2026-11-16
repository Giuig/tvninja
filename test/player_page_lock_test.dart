import 'dart:async';

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
import 'package:tvninja/services/video/engines/player_engine.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';
import 'package:tvninja/services/video/unified_video_player.dart';

/// Held shut by a test to keep the sound's `open()` in flight.
Completer<void>? _audioOpenGate;

/// What every fake below writes to, in the order it happened: the native
/// channel calls the page makes, the video engine's lifecycle and the sound
/// player's. Ordering is the point of several tests (the foreground service
/// before the stream opens; the old video connection gone before sound opens).
final List<String> _log = [];

/// A video engine that opens and plays nothing and lets a test fire the events
/// a real one reports.
class _FakeEngine extends PlayerEngine {
  _FakeEngine(this.rig, this.id,
      {required super.onPlaying,
      required super.onPosition,
      required super.onBuffering,
      required super.onEngineError});

  final _VideoRig rig;
  final int id;
  final openedUrls = <String>[];

  @override
  Future<void> open(String url, Map<String, String>? headers,
      {required bool autoPlay}) async {
    openedUrls.add(url);
    _log.add('video.open#$id');
  }

  @override
  Future<void> dispose() async {
    _log.add('video.dispose#$id');
    if (rig.disposeThrows) throw StateError('engine dispose failed');
  }

  @override
  Future<void> play() async => _log.add('video.play#$id');
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> switchTo(String url, Map<String, String>? headers) async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  bool get isPlaying => false;
  @override
  Duration get position => Duration.zero;

  @override
  Widget buildSurface(BuildContext context, {bool stretch = false}) =>
      SizedBox(key: Key('surface-$id'));

  void playing(bool value) => onPlaying(value);
  void buffering(bool value) => onBuffering(value);
  void firstFrame() => onPosition(const Duration(seconds: 1));
}

/// The video engines the player built, in order.
class _VideoRig {
  final engines = <_FakeEngine>[];

  /// Makes every engine's `dispose()` throw after it has been called.
  bool disposeThrows = false;
  _FakeEngine get last => engines.last;

  PlayerEngine create({
    required void Function(bool playing) onPlaying,
    required void Function(Duration position) onPosition,
    required void Function(bool buffering) onBuffering,
    required void Function(Object error) onEngineError,
  }) {
    final engine = _FakeEngine(this, engines.length,
        onPlaying: onPlaying,
        onPosition: onPosition,
        onBuffering: onBuffering,
        onEngineError: onEngineError);
    engines.add(engine);
    return engine;
  }
}

/// An mpv player that does nothing; a real one cannot be built on the test
/// host. `failOpen` is how a stream that cannot be opened looks to
/// `NativeAudioService.play`.
class _FakePlayer extends Fake implements mk.Player {
  _FakePlayer({this.failOpen = false});
  final bool failOpen;

  @override
  Future<void> open(mk.Playable playable,
      {bool play = true, Map<String, dynamic>? extras}) async {
    _log.add('audio.open');
    final gate = _audioOpenGate;
    if (gate != null) await gate.future;
    if (failOpen) throw StateError('cannot open');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  mk.PlayerState get state => const mk.PlayerState();
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
  @override
  Stream<Duration> get position => const Stream<Duration>.empty();
  @override
  Stream<String> get error => const Stream<String>.empty();
}

/// Drives the real `PlayerPage` through a screen lock and unlock: the app
/// lifecycle is delivered the way Android does it (`inactive`, `hidden`,
/// `paused` on the way down; `hidden`, `inactive`, `resumed` on the way up),
/// the native side is a stubbed method channel that answers `isInteractive`
/// and records everything else, the video engine and the sound player are
/// fakes.
///
/// Frames: while the app is `hidden` or `paused` Flutter produces none, which
/// is what keeps `UnifiedVideoPlayer` mounted (and shut down) for the whole lock
/// even though the page has already switched to its sound screen. The test
/// binding honours that, so a test that wants a frame behind the lock
/// delivers `inactive` (which re-enables frames) without `resumed`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const audioChannel = MethodChannel('io.github.giuig.tvninja/audio');
  const audioEvents = EventChannel('io.github.giuig.tvninja/audio_events');
  const pipEvents = EventChannel('io.github.giuig.tvninja/pip_events');
  const noisyEvents = EventChannel('io.github.giuig.tvninja/noisy_events');

  late _VideoRig rig;
  late List<MethodCall> audioCalls;
  late List<Object?> pipCalls;
  late bool screenInteractive;
  late bool refuseStart;
  late bool failAudioOpen;
  Completer<void>? stopGate;
  Completer<void>? startGate;
  MockStreamHandlerEventSink? nativeEvents;
  MockStreamHandlerEventSink? pipSink;
  MockStreamHandlerEventSink? noisySink;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
    _log.clear();
    _audioOpenGate = null;
    rig = _VideoRig();
    audioCalls = [];
    pipCalls = [];
    screenInteractive = false;
    refuseStart = false;
    failAudioOpen = false;
    stopGate = null;
    startGate = null;
    nativeEvents = null;
    pipSink = null;
    noisySink = null;
    UnifiedVideoPlayerState.engineFactory = rig.create;
    NativeAudioService.playerFactory =
        () => _FakePlayer(failOpen: failAudioOpen);

    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.giuig.tvninja/pip'), (call) async {
      if (call.method == 'setFullscreenVideoMode') pipCalls.add(call.arguments);
      return null;
    });
    messenger.setMockMethodCallHandler(audioChannel, (call) async {
      audioCalls.add(call);
      _log.add('channel:${call.method}');
      switch (call.method) {
        case 'isInteractive':
          return screenInteractive;
        case 'startBackground':
          if (refuseStart) throw PlatformException(code: 'FGS_NOT_ALLOWED');
          final gate = startGate;
          if (gate != null) await gate.future;
          return true;
        case 'stopBackground':
          final gate = stopGate;
          if (gate != null) await gate.future;
          return null;
      }
      return null;
    });
    // `setMockStreamHandler` lives on the messenger itself, not on the
    // channel: it keeps the sink so the test can push native events.
    messenger.setMockStreamHandler(audioEvents,
        MockStreamHandler.inline(onListen: (arguments, events) {
      nativeEvents = events;
    }));
    messenger.setMockStreamHandler(pipEvents,
        MockStreamHandler.inline(onListen: (arguments, events) {
      pipSink = events;
    }));
    messenger.setMockStreamHandler(noisyEvents,
        MockStreamHandler.inline(onListen: (arguments, events) {
      noisySink = events;
    }));
    for (final name in ['toggle', 'isEnabled']) {
      messenger.setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.$name',
          (message) async => const StandardMessageCodec()
              .encodeMessage(<Object?>[name == 'isEnabled' ? false : null]));
    }
  });

  tearDown(() async {
    // (A test may end locked; the test binding puts the lifecycle and the
    // frame switch back by itself after every test.)
    stopGate?.complete();
    startGate?.complete();
    _audioOpenGate?.complete();
    // `dispose` reaches for the audio player, which only exists once something
    // initialised the service.
    await NativeAudioService.initialize();
    await NativeAudioService.dispose();
    NativeAudioService.playerFactory = mk.Player.new;
    UnifiedVideoPlayerState.engineFactory = null;
    for (final events in [audioEvents, pipEvents, noisyEvents]) {
      messenger.setMockStreamHandler(events, null);
    }
  });

  /// Lets the page's chain of platform-channel round trips finish. They run
  /// partly in the fake-async zone (the test body's own calls) and partly on
  /// real time (the stubbed channels' replies), so it alternates the two.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
    }
    await tester.pump();
  }

  /// [settle] without building a frame: microtasks and channel replies only,
  /// for the moments where a frame would change what is being tested.
  Future<void> settleWithoutFrame(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.idle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
    }
    await tester.idle();
  }

  void deliverLifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      // ignore: invalid_use_of_protected_member
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  Future<void> lock(WidgetTester tester, {bool frameless = false}) async {
    deliverLifecycle(tester, [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    frameless ? await settleWithoutFrame(tester) : await settle(tester);
  }

  void startUnlock(WidgetTester tester) => deliverLifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);

  Future<void> unlock(WidgetTester tester) async {
    startUnlock(tester);
    await settle(tester);
  }

  Channel channel(String name) =>
      Channel(name: name, url: 'http://127.0.0.1:1/$name.m3u8');

  void cacheVideo(Channel c) => StreamKindCache.put(
      c.uniqueId,
      const StreamKindVerdict(
          StreamKind.video, KindConfidence.strong, KindSource.hlsMasterCodecs));

  Future<void> mountPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppStatsNotifier(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ));
    await settle(tester);
  }

  /// Opens a video channel and gets its picture playing.
  Future<Channel> openPlayingVideo(WidgetTester tester,
      {List<Channel>? channels}) async {
    final first = channels?.first ?? channel('tv');
    for (final c in channels ?? [first]) {
      cacheVideo(c);
    }
    await mountPage(
        tester,
        PlayerPage(
            channel: first,
            channels: channels,
            initialIndex: channels == null ? null : 0));
    expect(rig.engines, hasLength(1), reason: 'the video opened');
    rig.last
      ..firstFrame()
      ..playing(true);
    await settle(tester);
    return first;
  }

  void deliverNative(WidgetTester tester, String event) =>
      nativeEvents!.success(<String, dynamic>{'event': event});

  int count(String entry) => _log.where((e) => e == entry).length;
  int indexOf(String entry) => _log.indexOf(entry);

  testWidgets(
      'lock while video plays: the foreground service starts first, the old '
      'video is fully gone before sound opens the stream', (tester) async {
    await openPlayingVideo(tester);
    _log.clear();

    await lock(tester);

    expect(count('channel:isInteractive'), 1);
    expect(indexOf('channel:startBackground'),
        greaterThan(indexOf('channel:isInteractive')),
        reason: 'the screen is asked about before anything starts');
    expect(
        indexOf('audio.open'), greaterThan(indexOf('channel:startBackground')),
        reason: 'the service must be up before the stream opens: the app is '
            'already going to the background');
    expect(indexOf('video.dispose#0'), isNonNegative,
        reason: 'the video engine and its connection are shut down');
    expect(indexOf('audio.open'), greaterThan(indexOf('video.dispose#0')),
        reason: 'the stream is not pulled twice');
    expect(count('channel:startBackground'), 1,
        reason: 'play() must not start the service a second time');
    expect(count('channel:stopBackground'), 0,
        reason:
            'nothing may stop the service between its early start and play()');
    expect(rig.engines, hasLength(1),
        reason: 'no new video engine behind the lock');
    expect(pipCalls.last, isFalse,
        reason: 'sound mode is not picture-in-picture eligible');
  });

  testWidgets(
      'unlock after a lock handover returns to video: sound stopped, video '
      'reloaded', (tester) async {
    await openPlayingVideo(tester);
    await lock(tester);
    _log.clear();

    await unlock(tester);

    expect(count('channel:stopBackground'), 1,
        reason: 'the sound session ends');
    expect(rig.engines, hasLength(2), reason: 'a fresh video load');
    expect(rig.last.openedUrls, ['http://127.0.0.1:1/tv.m3u8']);
    expect(
        indexOf('video.open#1'), greaterThan(indexOf('channel:stopBackground')),
        reason: 'the sound stream is closed before the picture opens it');
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
    expect(find.byIcon(Icons.headphones), findsOneWidget,
        reason: 'video mode: the toggle offers sound again');
    expect(pipCalls.last, isTrue,
        reason: 'picture-in-picture is eligible again');
  });

  testWidgets('unlock before any frame restarts the very same shut-down player',
      (tester) async {
    await openPlayingVideo(tester);
    final before =
        tester.state<UnifiedVideoPlayerState>(find.byType(UnifiedVideoPlayer));
    await lock(tester, frameless: true);
    expect(before.isShutDown, isTrue,
        reason: 'no frame has run, so the player is still mounted, shut down');

    startUnlock(tester);
    await settleWithoutFrame(tester);

    expect(before.isShutDown, isFalse);
    expect(rig.engines, hasLength(2), reason: 'restartAfterShutDown reloads');
    await settle(tester);
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
    expect(
        identical(
            tester.state<UnifiedVideoPlayerState>(
                find.byType(UnifiedVideoPlayer)),
            before),
        isTrue,
        reason: 'the same State carried on: it was never unmounted');
  });

  testWidgets(
      'a frame behind the lock unmounts the video: it is never kept offstage',
      (tester) async {
    await openPlayingVideo(tester);
    await lock(tester, frameless: true);
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);

    // `inactive` re-enables frames without unlocking.
    deliverLifecycle(tester, [AppLifecycleState.inactive]);
    await settle(tester);

    expect(find.byType(UnifiedVideoPlayer, skipOffstage: false), findsNothing);
    expect(rig.engines, hasLength(1), reason: 'and nothing rebuilt an engine');
  });

  testWidgets(
      'a late "playing" from the shut-down engine does not reach the sound '
      'screen', (tester) async {
    await openPlayingVideo(tester);
    // Keep the sound's start in flight: that is the window in which nothing
    // else tells the page the video is not playing any more.
    _audioOpenGate = Completer<void>();
    await lock(tester, frameless: true);

    rig.engines[0].playing(true); // the dying engine's last word
    await settleWithoutFrame(tester);
    _audioOpenGate!.complete();
    _audioOpenGate = null;
    await settleWithoutFrame(tester);
    deliverLifecycle(tester, [AppLifecycleState.inactive]);
    await settle(tester);

    expect(find.byIcon(Icons.pause_circle_filled), findsNothing,
        reason: 'the sound screen must not claim something is playing');
    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
  });

  testWidgets('Stop during the lock cancels the return to video',
      (tester) async {
    await openPlayingVideo(tester);
    await lock(tester);
    deliverNative(tester, 'stopRequested');
    await settle(tester);

    await unlock(tester);

    expect(rig.engines, hasLength(1), reason: 'no video comes back');
    expect(find.byType(UnifiedVideoPlayer), findsNothing);
    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget,
        reason: 'stopped sound, its play button restarts it');
    expect(find.byIcon(Icons.videocam), findsOneWidget,
        reason: 'the way back to video is still the toggle');
    _log.clear();

    await tester.tap(find.byIcon(Icons.play_circle_filled));
    await settle(tester);
    expect(count('audio.open'), 1, reason: 'play restarts the sound');
  });

  testWidgets(
      'pausing the sound on the lock screen keeps it paused in sound mode',
      (tester) async {
    await openPlayingVideo(tester);
    await lock(tester);
    deliverNative(tester, 'pauseRequested');
    await settle(tester);

    await unlock(tester);

    expect(rig.engines, hasLength(1), reason: 'no video starts with sound');
    expect(find.byType(UnifiedVideoPlayer), findsNothing);
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(count('channel:stopBackground'), 0,
        reason: 'the paused session stays as the person left it');
  });

  testWidgets('a channel change during the lock cancels the return',
      (tester) async {
    final first = channel('one');
    final second = channel('two');
    await openPlayingVideo(tester, channels: [first, second]);
    await lock(tester, frameless: true);
    _log.clear();

    await tester.tap(find.byIcon(Icons.skip_next).first);
    await settleWithoutFrame(tester);
    await unlock(tester);

    expect(count('audio.open'), 1, reason: 'the new channel plays as sound');
    expect(find.byType(UnifiedVideoPlayer), findsNothing,
        reason: 'the zap did not reach the shut-down player');
    expect(rig.engines, hasLength(1));
    expect(count('channel:stopBackground'), 0);
  });

  testWidgets(
      'the manual sound toggle while the handover is starting cancels the '
      'return', (tester) async {
    await openPlayingVideo(tester);
    // The foreground service takes a while to answer; the page still shows
    // the video screen (no frame runs while locked, and the handover has not
    // switched it yet).
    startGate = Completer<void>();
    await lock(tester, frameless: true);
    expect(count('channel:startBackground'), 1);
    expect(count('video.dispose#0'), 0, reason: 'not shut down yet');

    await tester.tap(find.byIcon(Icons.headphones));
    await settleWithoutFrame(tester);
    startGate!.complete();
    startGate = null;
    await settleWithoutFrame(tester);
    await unlock(tester);

    expect(find.byType(UnifiedVideoPlayer), findsNothing);
    expect(rig.engines, hasLength(1),
        reason: 'the choice to hear sound stands');
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(count('audio.open'), 1, reason: 'one sound session, not two');
    expect(count('channel:startBackground'), 1,
        reason: 'and it keeps the service the lock started');
  });

  testWidgets(
      'Stop while the sound is still starting ends it: no sound, and never '
      'the video behind the lock', (tester) async {
    await openPlayingVideo(tester);
    _audioOpenGate = Completer<void>();
    await lock(tester, frameless: true);
    expect(count('audio.open'), 1, reason: 'the sound is opening');

    deliverNative(tester, 'stopRequested'); // the early notification's Stop
    await settleWithoutFrame(tester);
    _audioOpenGate!.complete();
    _audioOpenGate = null;
    await settleWithoutFrame(tester);

    // A frame behind the lock: still the sound screen, not a video fallback.
    deliverLifecycle(tester, [AppLifecycleState.inactive]);
    await settle(tester);
    expect(find.byType(UnifiedVideoPlayer), findsNothing,
        reason: 'a start cancelled by Stop is not a failure to fall back from');
    expect(rig.engines, hasLength(1));

    await unlock(tester);
    expect(find.byType(UnifiedVideoPlayer), findsNothing,
        reason: 'Stop cancelled the return');
    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
  });

  testWidgets(
      'a refusal reported while the foreground start is being answered '
      'leaves the video alone', (tester) async {
    await openPlayingVideo(tester);
    startGate = Completer<void>();
    await lock(tester, frameless: true);
    expect(count('channel:startBackground'), 1);

    deliverNative(tester, 'foregroundRefused');
    await settleWithoutFrame(tester);
    startGate!.complete();
    startGate = null;
    await settleWithoutFrame(tester);

    expect(count('video.dispose#0'), 0, reason: 'the video was not shut down');
    expect(count('audio.open'), 0,
        reason: 'and no sound opened without a service');
    await unlock(tester);
    expect(rig.engines, hasLength(1));
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
  });

  testWidgets(
      'unlock while the sound is still starting ends that session too and '
      'brings the video back', (tester) async {
    await openPlayingVideo(tester);
    _audioOpenGate = Completer<void>();
    await lock(tester, frameless: true);
    expect(count('audio.open'), 1, reason: 'the sound is opening');
    expect(count('channel:stopBackground'), 0);

    startUnlock(tester);
    await settleWithoutFrame(tester);
    _audioOpenGate!.complete();
    _audioOpenGate = null;
    await settle(tester);

    expect(count('channel:stopBackground'), greaterThanOrEqualTo(1),
        reason: 'the foreground service the lock started must not be left up');
    expect(count('channel:startBackground'), 1,
        reason: 'and the cancelled start must not start a service of its own');
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
    expect(rig.engines, hasLength(2), reason: 'the video starts afresh');
  });

  testWidgets(
      'a video engine that fails to dispose does not abandon the handover',
      (tester) async {
    await openPlayingVideo(tester);
    rig.disposeThrows = true;
    _log.clear();

    await lock(tester, frameless: true);

    expect(count('video.dispose#0'), 1, reason: 'the shutdown was attempted');
    expect(count('audio.open'), 1, reason: 'the sound still takes over');
    expect(count('channel:startBackground'), 1);
    expect(rig.engines, hasLength(1));
  });

  testWidgets('a video that is not playing stays untouched at lock',
      (tester) async {
    await openPlayingVideo(tester);
    rig.last.playing(false); // paused
    await settle(tester);
    _log.clear();

    await lock(tester);
    await unlock(tester);

    expect(count('channel:startBackground'), 0);
    expect(count('audio.open'), 0);
    expect(count('video.dispose#0'), 0);
    expect(count('channel:isInteractive'), 0,
        reason:
            'nothing could be handed over, so the screen is not even asked');
    expect(rig.engines, hasLength(1));
  });

  testWidgets(
      'a video the person paused while it buffered stays paused at lock',
      (tester) async {
    await openPlayingVideo(tester);
    noisySink!
        .success('becomingNoisy'); // pauses the video, like the pause button
    await settle(tester);
    rig.last
      ..playing(false)
      ..buffering(true);
    await settle(tester);
    _log.clear();

    await lock(tester);

    expect(count('channel:startBackground'), 0,
        reason: 'a stopped video must not start as sound');
    expect(rig.engines, hasLength(1));
  });

  testWidgets('a video still loading at lock is handed over', (tester) async {
    final c = channel('tv');
    cacheVideo(c);
    await mountPage(tester, PlayerPage(channel: c));
    expect(rig.engines, hasLength(1), reason: 'opened, no picture yet');
    rig.last.buffering(true);
    await settle(tester);
    _log.clear();

    await lock(tester);

    expect(count('channel:startBackground'), 1,
        reason:
            'it was about to be heard, so the lock must not leave it opening');
    expect(count('audio.open'), 1);
  });

  testWidgets('picture-in-picture is left alone at lock', (tester) async {
    await openPlayingVideo(tester);
    pipSink!.success(true);
    await settle(tester);
    _log.clear();

    await lock(tester);
    await unlock(tester);

    expect(count('channel:startBackground'), 0);
    expect(count('video.dispose#0'), 0);
    expect(rig.engines, hasLength(1));
  });

  testWidgets('a background move with the screen still on is not a lock',
      (tester) async {
    screenInteractive = true; // the shade, Home with PiP off, a dismissed PiP
    await openPlayingVideo(tester);
    _log.clear();

    await lock(tester);
    await unlock(tester);

    expect(count('channel:isInteractive'), 1);
    expect(count('channel:startBackground'), 0);
    expect(count('video.dispose#0'), 0);
    expect(rig.engines, hasLength(1));
  });

  testWidgets('a manual sound mode is untouched by lock and unlock',
      (tester) async {
    await openPlayingVideo(tester);
    await tester.tap(find.byIcon(Icons.headphones));
    await settle(tester);
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    _log.clear();

    await lock(tester);
    await unlock(tester);

    expect(count('channel:startBackground'), 0);
    expect(count('channel:stopBackground'), 0);
    expect(count('audio.open'), 0);
    expect(find.byType(UnifiedVideoPlayer), findsNothing);
  });

  testWidgets('a channel locked to audio is untouched by lock and unlock',
      (tester) async {
    final radio = channel('radio');
    StreamKindCache.put(
        radio.uniqueId,
        const StreamKindVerdict(StreamKind.audioOnly, KindConfidence.strong,
            KindSource.contentType));
    await mountPage(tester, PlayerPage(channel: radio));
    expect(rig.engines, isEmpty);
    expect(count('audio.open'), 1);
    _log.clear();

    await lock(tester);
    await unlock(tester);

    expect(count('channel:startBackground'), 0);
    expect(count('channel:stopBackground'), 0);
    expect(count('audio.open'), 0);
    expect(rig.engines, isEmpty, reason: 'no video for a locked audio channel');
  });

  testWidgets(
      'the foreground service refused: nothing is shut down, the video '
      'carries on after unlock', (tester) async {
    refuseStart = true;
    await openPlayingVideo(tester);
    _log.clear();

    await lock(tester);

    expect(count('channel:startBackground'), 1, reason: 'it was tried');
    expect(count('audio.open'), 0, reason: 'no sound without a service');
    expect(count('video.dispose#0'), 0, reason: 'the video was not shut down');
    expect(count('channel:stopBackground'), 0, reason: 'nothing to stop');

    await unlock(tester);

    expect(rig.engines, hasLength(1), reason: 'the same video, not reloaded');
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
    expect(count('channel:stopBackground'), 0);
  });

  testWidgets(
      'the stream cannot be opened while locked: the service is stopped, no '
      'error screen, a cold video start on unlock', (tester) async {
    failAudioOpen = true;
    await openPlayingVideo(tester);
    _log.clear();

    await lock(tester, frameless: true);

    expect(count('channel:startBackground'), 1);
    expect(count('audio.open'), 1);
    expect(count('channel:stopBackground'), 1,
        reason: 'the early service ends: no empty notification or wake lock');
    expect(rig.engines, hasLength(1),
        reason: 'no video fallback behind the lock');

    // A frame behind the lock: the sound screen, not an error and not video.
    deliverLifecycle(tester, [AppLifecycleState.inactive]);
    await settle(tester);
    expect(find.byIcon(Icons.refresh), findsNothing, reason: 'no error screen');
    expect(find.byType(UnifiedVideoPlayer), findsNothing);
    expect(rig.engines, hasLength(1));

    await unlock(tester);

    expect(rig.engines, hasLength(2), reason: 'a cold video start');
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets(
      'an unlock and a second lock back to back: the return finishes, then the '
      'new lock hands over again', (tester) async {
    await openPlayingVideo(tester);
    await lock(tester);
    _log.clear();

    // The sound session's stop is slow: the return is still running when the
    // screen locks again.
    stopGate = Completer<void>();
    startUnlock(tester);
    await settleWithoutFrame(tester);
    expect(count('channel:stopBackground'), 1);
    await lock(tester, frameless: true);
    expect(count('channel:startBackground'), 0,
        reason: 'not while the previous return is still stopping the sound');

    stopGate!.complete();
    stopGate = null;
    await settleWithoutFrame(tester);
    await settleWithoutFrame(tester);

    expect(count('channel:startBackground'), 1,
        reason: 'the second lock hands over once the return is done');
    expect(indexOf('channel:startBackground'),
        greaterThan(indexOf('channel:stopBackground')));
    expect(count('audio.open'), 1);

    await unlock(tester);
    expect(find.byType(UnifiedVideoPlayer), findsOneWidget,
        reason: 'and the final unlock ends in video');
  });

  testWidgets('a handover waits for a sound session that is still stopping',
      (tester) async {
    await openPlayingVideo(tester);
    // Something else ended a sound session and its stop is still in flight
    // (its `stopBackground` goes out last): a service started now would be
    // stopped by it.
    await NativeAudioService.initialize();
    stopGate = Completer<void>();
    final stopping = NativeAudioService.stop();
    await settleWithoutFrame(tester);
    expect(count('channel:stopBackground'), 1);
    _log.clear();

    await lock(tester, frameless: true);
    expect(count('channel:startBackground'), 0,
        reason: 'the foreground service must not start under a pending stop');

    stopGate!.complete();
    stopGate = null;
    await stopping;
    await settleWithoutFrame(tester);
    await settleWithoutFrame(tester);

    expect(count('channel:startBackground'), 1);
    expect(count('audio.open'), 1);
  });
}
