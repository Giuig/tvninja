import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_probe.dart';

/// Exercises `StreamKindProbe.probe` against a real loopback `HttpServer` --
/// the timeout/cap behaviour and the capped body read both depend on
/// dart:io's actual `HttpClient`, which the pure `stream_kind_test.dart`
/// suite never touches.
void main() {
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://${server.address.address}:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('an audio Content-Type settles it from headers alone', () async {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'audio/mpeg')
        ..statusCode = 200
        ..write('ignored')
        ..close();
    });

    final verdict = (await StreamKindProbe.probe('$baseUrl/stream', null)).verdict;

    expect(verdict.kind, StreamKind.audioOnly);
    expect(verdict.confidence, KindConfidence.strong);
    expect(verdict.source, KindSource.contentType);
  });

  test('icy-* headers settle it when Content-Type is absent', () async {
    server.listen((request) {
      request.response
        ..headers.set('icy-name', 'Test Radio')
        ..statusCode = 200
        ..close();
    });

    final verdict = (await StreamKindProbe.probe('$baseUrl/stream', null)).verdict;

    expect(verdict.kind, StreamKind.audioOnly);
    expect(verdict.source, KindSource.icyHeader);
  });

  test('an HLS master body is read and classified', () async {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'application/vnd.apple.mpegurl')
        ..statusCode = 200
        ..write('#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=67171,CODECS="mp4a.40.5"\n'
            'audio/playlist.m3u8\n')
        ..close();
    });

    final verdict = (await StreamKindProbe.probe('$baseUrl/live.m3u8', null)).verdict;

    expect(verdict.kind, StreamKind.audioOnly);
    expect(verdict.confidence, KindConfidence.strong);
    expect(verdict.source, KindSource.hlsMasterCodecs);
  });

  test('a muxed master also yields the sound-mode URI, unjoined', () async {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'application/vnd.apple.mpegurl')
        ..statusCode = 200
        ..write('#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
            'v_720.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
            'v_360.m3u8\n')
        ..close();
    });

    final result = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

    expect(result.verdict.kind, StreamKind.video);
    // Relative, exactly as the playlist wrote it -- joining it against a
    // freshly resolved master is the caller's job, since this value gets
    // cached for days and an absolute URL's token would not survive that.
    expect(result.soundModeUri, 'v_360.m3u8');
  });

  test('an audio rendition wins over the variants', () async {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'application/vnd.apple.mpegurl')
        ..statusCode = 200
        ..write('#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="it",DEFAULT=YES,URI="audio_it.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="a"\n'
            'v_360.m3u8\n')
        ..close();
    });

    final result = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

    expect(result.soundModeUri, 'audio_it.m3u8');
  });

  test('a header-settled stream carries no sound-mode URI', () async {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'audio/mpeg')
        ..statusCode = 200
        ..write('ignored')
        ..close();
    });

    final result = await StreamKindProbe.probe('$baseUrl/stream', null);

    expect(result.verdict.kind, StreamKind.audioOnly);
    // A progressive stream has no variants to choose between at all.
    expect(result.soundModeUri, isNull);
  });

  /// Redirects [from] to [to], and serves a muxed master for anything else.
  void serveRedirect(String from, String to) {
    server.listen((request) {
      if (request.uri.path == from) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('location', to)
          ..close();
        return;
      }
      request.response
        ..headers.set('content-type', 'application/vnd.apple.mpegurl')
        ..statusCode = 200
        ..write('#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
            'v_720.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
            'v_360.m3u8\n')
        ..close();
    });
  }

  test('a direct .m3u8 that redirects out of its directory is not pinned',
      () async {
    // Nothing resolves a `.m3u8` at open time, so the relative pin would be
    // joined against the pre-redirect path and point at nothing. Better to
    // leave the channel on today's behaviour than to waste an open per start.
    serveRedirect('/live.m3u8', '/elsewhere/master.m3u8');

    final result = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

    // Still classified -- only the pin is withheld.
    expect(result.verdict.kind, StreamKind.video);
    expect(result.soundModeUri, isNull);
  });

  test('a redirect that stays in the same directory still pins', () async {
    // The original URL is a correct base for a sibling URI either way.
    serveRedirect('/live.m3u8', '/master.m3u8');

    final result = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

    expect(result.verdict.kind, StreamKind.video);
    expect(result.soundModeUri, 'v_360.m3u8');
  });

  test('a multi-hop chain is resolved per hop, not against the original',
      () async {
    // `RedirectInfo.location` is the raw `Location` header of that hop --
    // dart:io does not write a resolved absolute URI back onto it -- so each
    // hop must be resolved against the previous one. Here hop 1 goes to
    // `/deep/x.m3u8` and hop 2 is the relative `master.m3u8`, which really
    // lands in `/deep/`. Resolving only the last hop against the original URL
    // instead yields `/master.m3u8`, reads as "same directory as
    // /live.m3u8", and would pin a URI whose base is wrong by a directory.
    server.listen((request) {
      switch (request.uri.path) {
        case '/live.m3u8':
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/deep/x.m3u8')
            ..close();
        case '/deep/x.m3u8':
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location', 'master.m3u8')
            ..close();
        default:
          request.response
            ..headers.set('content-type', 'application/vnd.apple.mpegurl')
            ..statusCode = 200
            ..write('#EXTM3U\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
                'v_720.m3u8\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
                'v_360.m3u8\n')
            ..close();
      }
    });

    final result = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

    expect(result.verdict.kind, StreamKind.video);
    expect(result.soundModeUri, isNull);
  });

  test('a suffix-less URL that redirects away is still pinned', () async {
    // A relinker: `NativeAudioService` resolves it on Dart's stack before
    // every open and joins against the result, so the redirect is handled.
    serveRedirect('/relinker', '/cdn/abc/master.m3u8');

    final result = await StreamKindProbe.probe('$baseUrl/relinker', null);

    expect(result.soundModeUri, 'v_360.m3u8');
  });

  test('a non-2xx status is unknown, no body read attempted', () async {
    server.listen((request) {
      request.response
        ..statusCode = 404
        ..close();
    });

    final verdict = (await StreamKindProbe.probe('$baseUrl/gone', null)).verdict;

    expect(verdict, StreamKindVerdict.unknown);
  });

  test(
    'a stalled server degrades to unknown within cap + 100ms',
    () async {
      server.listen((request) {
        // Deliberately never respond -- a dead/hung provider.
      });

      final stopwatch = Stopwatch()..start();
      final verdict = (await StreamKindProbe.probe('$baseUrl/stall', null)).verdict;
      stopwatch.stop();

      expect(verdict, StreamKindVerdict.unknown);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1300)));
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'a body over 64KB is capped, trailing partial line dropped, still classified correctly',
    () async {
      // Every complete line is a plain audio segment -- ~45 bytes each,
      // 1600 of them comfortably clears the 64KB cap while the segment
      // straddling the boundary is guaranteed to land mid-filename.
      final buffer = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n');
      for (var i = 0; i < 1600; i++) {
        buffer.write('#EXTINF:10.0,\n');
        buffer.write('segment_${i.toString().padLeft(6, '0')}_of_the_set.aac\n');
      }
      final playlist = buffer.toString();
      expect(playlist.length, greaterThan(64 * 1024));

      server.listen((request) {
        request.response
          ..headers.set('content-type', 'application/vnd.apple.mpegurl')
          ..statusCode = 200
          ..write(playlist)
          ..close();
      });

      final verdict = (await StreamKindProbe.probe('$baseUrl/live.m3u8', null)).verdict;

      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.source, KindSource.hlsMediaPlaylist);
    },
  );

  test('never throws -- an unreachable host degrades to unknown', () async {
    // A port nothing listens on, on the loopback address that was just
    // freed by tearDown-worthy cleanup -- guaranteed connection refused.
    final refusedPort = server.port;
    await server.close(force: true);

    final verdict = (await StreamKindProbe.probe(
      'http://127.0.0.1:$refusedPort/nothing-here',
      null,
    ))
        .verdict;

    expect(verdict, StreamKindVerdict.unknown);

    // Re-open a server so tearDown's close() has something valid to act on.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  test(
    'a redirect loop past the redirect limit degrades to unknown, never audio',
    () async {
      // Every request 302s straight back to itself -- an unbounded loop
      // that never settles on a final response. A channel behind a
      // misconfigured or looping relinker looks exactly like this, and a
      // failure of this shape must never be read as evidence of anything,
      // strong audio least of all -- it would otherwise lock a real TV
      // channel into audio mode for the strong-audio cache TTL.
      server.listen((request) {
        request.response
          ..statusCode = 302
          ..headers.set('location', '$baseUrl/loop')
          ..close();
      });

      final verdict = (await StreamKindProbe.probe('$baseUrl/loop', null)).verdict;

      expect(verdict, StreamKindVerdict.unknown);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'a malformed, non-HTTP response degrades to unknown, never audio',
    () async {
      // A raw socket server, bypassing HttpServer entirely, so the client
      // is handed bytes that don't parse as an HTTP response at all --
      // this is the actual shape of the failure a legacy `ICY 200 OK`
      // status line was once (wrongly) special-cased to treat as strong
      // audio evidence. Any response dart:io's HttpClient can't parse must
      // degrade the same way as every other failure: unknown, not a
      // locking verdict.
      final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => rawServer.close());
      rawServer.listen((socket) {
        socket.add(utf8.encode('NOT AN HTTP RESPONSE AT ALL\r\n\r\n'));
        socket.close();
      });

      final verdict = (await StreamKindProbe.probe(
        'http://127.0.0.1:${rawServer.port}/garbage',
        null,
      ))
          .verdict;

      expect(verdict, StreamKindVerdict.unknown);
    },
  );
}
