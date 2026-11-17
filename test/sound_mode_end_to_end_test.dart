import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';
import 'package:tvninja/services/video/stream_kind_classifier.dart';

/// The whole sound-mode pin chain against a real loopback server: classify a
/// channel, cache what the probe picked, read it back the way the player page
/// does, and join it into the URL mpv would be handed.
///
/// Everything except mpv itself, which cannot run under `flutter test` — so
/// the one step not covered here is `Player.open()` actually accepting the
/// URL. That is what the device run is for.
void main() {
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://${server.address.address}:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// Serves [body] as an HLS playlist for any request.
  void serve(String body) {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'application/vnd.apple.mpegurl')
        ..statusCode = 200
        ..write(body)
        ..close();
    });
  }

  String join(String master, String uri) =>
      NativeAudioService.joinSoundModeUriForTest(master, uri);

  test('a muxed master ends up opening the lowest variant', () async {
    serve('#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
        'v_720.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
        'v_360.m3u8\n');
    final channel = Channel(name: 'TV', url: '$baseUrl/live/master.m3u8');

    // What the player page awaits before it decides the mode.
    final verdict = await StreamKindClassifier.classify(channel);
    expect(verdict.kind, StreamKind.video);

    // What `_startNativeAudio` then reads, synchronously, off the cache.
    final pin = StreamKindClassifier.peekSoundModeUri(channel);
    expect(pin, 'v_360.m3u8');

    // A direct `.m3u8` needs no resolving, so the channel URL is the base.
    expect(join(channel.url, pin!), '$baseUrl/live/v_360.m3u8');
  });

  test('a master with an audio rendition opens the rendition', () async {
    serve('#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="it",DEFAULT=YES,URI="audio_it.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720,AUDIO="a"\n'
        'v_720.m3u8\n');
    final channel = Channel(name: 'TV', url: '$baseUrl/live/master.m3u8');

    await StreamKindClassifier.classify(channel);

    final pin = StreamKindClassifier.peekSoundModeUri(channel);
    expect(pin, 'audio_it.m3u8');
    expect(join(channel.url, pin!), '$baseUrl/live/audio_it.m3u8');
  });

  test('a single-variant master pins nothing, so the master is opened',
      () async {
    serve('#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
        'only.m3u8\n');
    final channel = Channel(name: 'TV', url: '$baseUrl/live/master.m3u8');

    await StreamKindClassifier.classify(channel);

    expect(StreamKindClassifier.peekSoundModeUri(channel), isNull);
  });

  test('a radio channel is never probed and never pinned', () async {
    final channel = Channel(
      name: 'Radio',
      url: 'http://127.0.0.1:1/unreachable',
      isRadio: true,
    );

    expect(StreamKindClassifier.peekSoundModeUri(channel), isNull);
  });

  test('the pin survives a cache round-trip, still relative', () async {
    serve('#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
        'v_720.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
        'v_360.m3u8\n');
    final channel = Channel(name: 'TV', url: '$baseUrl/live/master.m3u8');

    await StreamKindClassifier.classify(channel);
    await Future<void>.delayed(Duration.zero); // let the persist land

    StreamKindCache.resetForTest();
    await StreamKindCache.load();

    // Relative after the round-trip, not an absolute URL carrying a token
    // that would already be days old by the time it is read.
    expect(StreamKindClassifier.peekSoundModeUri(channel), 'v_360.m3u8');
  });

  test('an unreachable channel pins nothing and stays playable', () async {
    final channel = Channel(name: 'TV', url: 'http://127.0.0.1:1/dead.m3u8');

    final verdict = await StreamKindClassifier.classify(channel);

    expect(verdict, StreamKindVerdict.unknown);
    expect(StreamKindClassifier.peekSoundModeUri(channel), isNull);
  });
}
