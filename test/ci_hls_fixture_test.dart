import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_probe.dart';

/// Guards the HLS fixtures in `integration_test/fixtures/` against the real
/// classifier, here, where it costs seconds.
///
/// The emulator test that uses them takes ~15 minutes and only runs on a PR
/// carrying the `e2e` label or on a push to `main`. A malformed fixture would
/// therefore fail slowly, remotely, and ambiguously — the failure would look
/// like "the pin is broken" when it was the fixture all along. These serve the
/// same files over loopback and assert the pick the device test depends on.
void main() {
  late HttpServer server;
  late String base;
  final dir = Directory('integration_test/fixtures');

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      final name = request.uri.pathSegments.isEmpty
          ? ''
          : request.uri.pathSegments.last;
      final file = File('${dir.path}/$name');
      if (!file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = name.endsWith('.m3u8')
          ? ContentType('application', 'vnd.apple.mpegurl')
          : ContentType('video', 'mp2t');
      await request.response.addStream(file.openRead());
      await request.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  test('the fixture files are all present', () {
    for (final name in [
      'pin_master.m3u8',
      'pin_rend_master.m3u8',
      'pin_v_low.m3u8',
      'pin_v_mid.m3u8',
      'pin_v_high.m3u8',
      'pin_audio.m3u8',
      'pin_seg.ts',
    ]) {
      expect(File('${dir.path}/$name').existsSync(), isTrue,
          reason: '$name is missing; the emulator test needs it');
    }
  });

  test('the muxed master pins the LOWEST variant, which is listed last',
      () async {
    final result = await StreamKindProbe.probe('$base/pin_master.m3u8', null);

    expect(result.verdict.kind, StreamKind.video);
    // Listed last in the file, cheapest by BANDWIDTH. If this ever comes back
    // as pin_v_high.m3u8 the pick has regressed to "first variant wins".
    expect(result.soundModeUri, 'pin_v_low.m3u8');
  });

  test('the rendition master pins the audio rendition, not a variant',
      () async {
    final result =
        await StreamKindProbe.probe('$base/pin_rend_master.m3u8', null);

    expect(result.verdict.kind, StreamKind.video);
    expect(result.soundModeUri, 'pin_audio.m3u8');
  });

  test('every media playlist the fixtures point at is a real media playlist',
      () async {
    // Guards against a copy-paste that leaves a variant pointing at a master,
    // which would make the device test loop instead of play.
    for (final name in [
      'pin_v_low.m3u8',
      'pin_v_mid.m3u8',
      'pin_v_high.m3u8',
      'pin_audio.m3u8'
    ]) {
      final body = File('${dir.path}/$name').readAsStringSync();
      expect(body.contains('#EXT-X-STREAM-INF:'), isFalse,
          reason: '$name must not be a master');
      expect(body.contains('pin_seg.ts'), isTrue,
          reason: '$name must point at the segment');
      expect(body.contains('#EXT-X-ENDLIST'), isTrue,
          reason: '$name must be a finite VOD playlist, or the test will '
              'wait for a live edge that never moves');
    }
  });

  test('the segment is audio the player can actually open', () {
    final seg = File('${dir.path}/pin_seg.ts');
    // 188-byte MPEG-TS packets, each starting with the sync byte 0x47.
    final head = seg.readAsBytesSync().take(188 * 2).toList();
    expect(head.first, 0x47, reason: 'not an MPEG-TS stream');
    expect(head[188], 0x47, reason: 'TS packet alignment is wrong');
    expect(seg.lengthSync(), greaterThan(20000),
        reason: 'too short for the player to report playing');
  });
}
