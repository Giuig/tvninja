import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:tvninja/services/native_audio_service.dart';

/// Records the URL each open was given. A real mpv player cannot be built on
/// the test host, and what matters here is which URL reached it.
class _RecordingPlayer extends Fake implements mk.Player {
  _RecordingPlayer({this.failOpen = false});

  final bool failOpen;
  final opened = <String>[];

  @override
  Future<void> open(mk.Playable playable,
      {bool play = true, Map<String, dynamic>? extras}) async {
    opened.add((playable as mk.Media).uri);
    if (failOpen) throw StateError('cannot open');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  mk.PlayerStream get stream => _FakePlayerStream();

  /// Reports playing, so `play`'s "same URL already playing, skip recreation"
  /// guard is actually reachable in a test.
  @override
  mk.PlayerState get state => _FakeState();
}

class _FakeState extends Fake implements mk.PlayerState {
  @override
  bool get playing => true;
  @override
  bool get buffering => false;
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

/// Which URL sound mode actually hands mpv, and which of the service's three
/// URL fields holds what.
///
/// This is the layer the unit tests were missing: `sound_mode_uri_test` covers
/// the parser, `sound_mode_pin_test` the join, `sound_mode_end_to_end_test`
/// the classify/cache/peek chain — but nothing exercised `play`'s own field
/// choices, which is where a wrong field breaks reconnects or leaks a previous
/// channel's URL.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.github.giuig.tvninja/audio');
  const eventChannel = EventChannel('io.github.giuig.tvninja/audio_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final players = <_RecordingPlayer>[];
  var failOpen = false;

  setUp(() async {
    // `TestWidgetsFlutterBinding` (needed above for the method-channel mocks)
    // installs an `HttpOverrides` that answers every `HttpClient` request with
    // a 400. `StreamUrlResolver` runs on `dart:io`, so without this the pin
    // resolution silently fails and every test here would pass for the wrong
    // reason — reading as "not pinned" rather than "pinned correctly".
    HttpOverrides.global = null;
    players.clear();
    failOpen = false;
    NativeAudioService.playerFactory = () {
      final player = _RecordingPlayer(failOpen: failOpen);
      players.add(player);
      return player;
    };
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    messenger.setMockStreamHandler(
        eventChannel, MockStreamHandler.inline(onListen: (_, __) {}));
    // Don't let static state from an earlier test leak in.
    await NativeAudioService.initialize();
    await NativeAudioService.dispose();
    players.clear();
  });

  tearDown(() async {
    await NativeAudioService.stop();
    await NativeAudioService.dispose();
    NativeAudioService.playerFactory = mk.Player.new;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  _RecordingPlayer player() => players.last;

  group('what play() opens', () {
    test('a pin on a direct .m3u8 is joined and opened', () async {
      expect(
        await NativeAudioService.play(
          url: 'https://cdn.example.com/live/master.m3u8',
          soundModeUri: 'v_360.m3u8',
        ),
        isTrue,
      );

      expect(player().opened, ['https://cdn.example.com/live/v_360.m3u8']);
      expect(NativeAudioService.debugOpenedUrl,
          'https://cdn.example.com/live/v_360.m3u8');
      // The master is kept as the fallback...
      expect(NativeAudioService.debugMasterUrl,
          'https://cdn.example.com/live/master.m3u8');
      // ...and the pin itself stays relative, so it can be re-joined later.
      expect(NativeAudioService.debugSoundModeUri, 'v_360.m3u8');
    });

    test('currentUrl stays the channel, not what was opened', () async {
      // Load-bearing: play()'s own same-URL guard, the home page and the
      // channel list all compare currentUrl against a channel's url.
      const url = 'https://cdn.example.com/live/master.m3u8';
      await NativeAudioService.play(url: url, soundModeUri: 'v_360.m3u8');

      expect(NativeAudioService.currentUrl, url);
      expect(NativeAudioService.debugOpenedUrl, isNot(url));
    });

    test('the same-URL guard still skips recreation for a pinned channel',
        () async {
      const url = 'https://cdn.example.com/live/master.m3u8';
      await NativeAudioService.play(url: url, soundModeUri: 'v_360.m3u8');
      final first = players.length;

      await NativeAudioService.play(url: url, soundModeUri: 'v_360.m3u8');

      // A second player would mean the guard stopped matching, which is what
      // passing the pinned URL in as `url` would have caused.
      expect(players.length, first);
    });

    test('no pin means the channel URL is opened, as before', () async {
      const url = 'https://cdn.example.com/live/master.m3u8';
      await NativeAudioService.play(url: url);

      expect(player().opened, [url]);
      expect(NativeAudioService.debugOpenedUrl, url);
      expect(NativeAudioService.debugMasterUrl, isNull);
      expect(NativeAudioService.debugSoundModeUri, isNull);
    });

    test('a pin on an unresolvable relinker is not applied', () async {
      // Suffix-less, so it needs resolving; nothing listens on port 1, so the
      // resolve fails and the channel must open unpinned rather than be
      // joined against a base known to be wrong.
      const url = 'http://127.0.0.1:1/relinker';
      await NativeAudioService.play(url: url, soundModeUri: 'v_360.m3u8');

      expect(player().opened, [url]);
      expect(NativeAudioService.debugMasterUrl, isNull);
    });

    test('zapping to another channel never opens the previous URL', () async {
      await NativeAudioService.play(
        url: 'https://cdn.example.com/a/master.m3u8',
        soundModeUri: 'v_360.m3u8',
      );
      await NativeAudioService.play(
        url: 'https://cdn.example.com/b/master.m3u8',
        soundModeUri: 'v_180.m3u8',
      );

      expect(NativeAudioService.debugOpenedUrl,
          'https://cdn.example.com/b/v_180.m3u8');
      expect(player().opened.last, 'https://cdn.example.com/b/v_180.m3u8');
    });

    test('a start whose open fails gives the pin up', () async {
      failOpen = true;
      expect(
        await NativeAudioService.play(
          url: 'https://cdn.example.com/live/master.m3u8',
          soundModeUri: 'v_360.m3u8',
        ),
        isFalse,
      );

      // So the page's Retry, and any later start of this channel, go back to
      // what the app opened before pinning existed.
      expect(NativeAudioService.debugSoundModeUri, isNull);
      expect(NativeAudioService.debugMasterUrl, isNull);
    });

    test('stop() clears all three URL fields', () async {
      await NativeAudioService.play(
        url: 'https://cdn.example.com/live/master.m3u8',
        soundModeUri: 'v_360.m3u8',
      );
      await NativeAudioService.stop();

      expect(NativeAudioService.currentUrl, isNull);
      expect(NativeAudioService.debugOpenedUrl, isNull);
      expect(NativeAudioService.debugMasterUrl, isNull);
      expect(NativeAudioService.debugSoundModeUri, isNull);
    });
  });

  group('the pin is rebuilt, never reused', () {
    late HttpServer relinker;
    late String relinkerUrl;
    var target = 'first';
    /// How long the servlet sits on the request, so a resolve can be caught
    /// still pending while something else happens.
    var slowBy = Duration.zero;

    setUp(() async {
      target = 'first';
      slowBy = Duration.zero;
      relinker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      relinkerUrl =
          'http://${relinker.address.address}:${relinker.port}/relinker';
      relinker.listen((request) async {
        if (slowBy > Duration.zero) await Future<void>.delayed(slowBy);
        // A relinker: no format suffix, 302 to a tokenised playlist whose
        // path changes whenever the provider reissues it. Only the servlet
        // path redirects — answering every path with a 302 would be a
        // redirect loop, and the resolve would fail rather than resolve.
        if (request.uri.path == '/relinker') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/cdn/$target/master.m3u8')
            ..close();
          return;
        }
        request.response
          ..statusCode = 200
          ..headers.set('content-type', 'application/vnd.apple.mpegurl')
          ..write('#EXTM3U\n')
          ..close();
      });
    });

    tearDown(() async => relinker.close(force: true));

    test('a second resolve picks up the provider\'s new playlist', () async {
      await NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );
      expect(NativeAudioService.debugOpenedUrl, endsWith('/cdn/first/v_360.m3u8'));

      // The provider reissues the stream somewhere else, as a relinker or an
      // expiring token does.
      target = 'second';
      await NativeAudioService.resolveOpenUrlForTest();

      // The regression this pins: storing the joined URL once and reopening
      // that string left a tokenised channel retrying a dead URL until the
      // chain gave up, where before the pin existed every reopen re-resolved.
      expect(
          NativeAudioService.debugOpenedUrl, endsWith('/cdn/second/v_360.m3u8'));
      expect(NativeAudioService.debugMasterUrl,
          endsWith('/cdn/second/master.m3u8'));
    });

    test('a reconnect gives up a pin that never played', () async {
      await NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );
      expect(NativeAudioService.debugSoundModeUri, 'v_360.m3u8');

      // Nothing has reported progress, so this pin is the suspect.
      await NativeAudioService.reopenForTest();

      expect(NativeAudioService.debugSoundModeUri, isNull);
      expect(NativeAudioService.debugMasterUrl, isNull);
      // Back to the channel URL — which for a relinker is the *better* master
      // fallback than the resolved playlist, since mpv follows the redirect
      // itself and so gets a freshly issued token. It is also exactly what the
      // app opened before pinning existed.
      expect(NativeAudioService.debugOpenedUrl, relinkerUrl);
      expect(player().opened.last, relinkerUrl);
    });

    test('a zap during a slow resolve does not get the old channel opened',
        () async {
      // The race: A is a relinker, so its resolve awaits. B is zapped to while
      // that await is pending. If the resolve writes the shared URL fields
      // when it finally returns, it overwrites B's with A's and B plays A's
      // stream under B's identity.
      //
      // Deliberately overlapping: the other zap test awaits A to completion
      // first and so cannot see this at all.
      slowBy = const Duration(milliseconds: 700);
      final pendingA = NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );
      // Let A get as far as its resolve.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // B is a direct `.m3u8`, so it needs no resolve and completes at once.
      await NativeAudioService.play(
        url: 'https://cdn.example.com/b/master.m3u8',
        soundModeUri: 'v_180.m3u8',
      );
      // Now let A's resolve come back.
      await pendingA;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(NativeAudioService.currentUrl,
          'https://cdn.example.com/b/master.m3u8');
      expect(NativeAudioService.debugOpenedUrl,
          'https://cdn.example.com/b/v_180.m3u8');
      expect(NativeAudioService.debugMasterUrl,
          'https://cdn.example.com/b/master.m3u8');
      expect(player().opened.last, 'https://cdn.example.com/b/v_180.m3u8');
    });

    test('a stop during a slow resolve leaves nothing behind', () async {
      slowBy = const Duration(milliseconds: 700);
      final pendingA = NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await NativeAudioService.stop();
      await pendingA;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // A resolve that lands after the stop must not repopulate the fields.
      expect(NativeAudioService.currentUrl, isNull);
      expect(NativeAudioService.debugOpenedUrl, isNull);
      expect(NativeAudioService.debugMasterUrl, isNull);
      expect(NativeAudioService.debugSoundModeUri, isNull);
    });

    test('a zap during a slow reconnect rebuild drops the rebuild', () async {
      // The reconnect half of the same race. `play()` is protected by its own
      // canceller; the reconnect path has only `_refreshOpenUrl`'s identity
      // check, and deleting that check left every other test green. These two
      // are what make it fail.
      await NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );

      slowBy = const Duration(milliseconds: 700);
      final pendingRebuild = NativeAudioService.resolveOpenUrlForTest();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await NativeAudioService.play(
        url: 'https://cdn.example.com/b/master.m3u8',
        soundModeUri: 'v_180.m3u8',
      );
      await pendingRebuild;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The rebuild was computed for the old channel: its result must be
      // thrown away, not written over the new one's.
      expect(NativeAudioService.debugOpenedUrl,
          'https://cdn.example.com/b/v_180.m3u8');
      expect(NativeAudioService.debugMasterUrl,
          'https://cdn.example.com/b/master.m3u8');
      expect(NativeAudioService.debugSoundModeUri, 'v_180.m3u8');
    });

    test('a stop during a slow reconnect rebuild drops the rebuild', () async {
      await NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );

      slowBy = const Duration(milliseconds: 700);
      final pendingRebuild = NativeAudioService.resolveOpenUrlForTest();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await NativeAudioService.stop();
      await pendingRebuild;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // `stop()` does not bump the request id, so this one is caught by the
      // channel-URL comparison instead.
      expect(NativeAudioService.currentUrl, isNull);
      expect(NativeAudioService.debugOpenedUrl, isNull);
      expect(NativeAudioService.debugMasterUrl, isNull);
    });

    test('once given up, a later reconnect does not pin again', () async {
      await NativeAudioService.play(
        url: relinkerUrl,
        soundModeUri: 'v_360.m3u8',
      );
      await NativeAudioService.reopenForTest();
      await NativeAudioService.reopenForTest();

      expect(NativeAudioService.debugSoundModeUri, isNull);
      expect(player().opened.last, relinkerUrl);
    });
  });
}
