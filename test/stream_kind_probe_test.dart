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

    final verdict = await StreamKindProbe.probe('$baseUrl/stream', null);

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

    final verdict = await StreamKindProbe.probe('$baseUrl/stream', null);

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

    final verdict = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

    expect(verdict.kind, StreamKind.audioOnly);
    expect(verdict.confidence, KindConfidence.strong);
    expect(verdict.source, KindSource.hlsMasterCodecs);
  });

  test('a non-2xx status is unknown, no body read attempted', () async {
    server.listen((request) {
      request.response
        ..statusCode = 404
        ..close();
    });

    final verdict = await StreamKindProbe.probe('$baseUrl/gone', null);

    expect(verdict, StreamKindVerdict.unknown);
  });

  test(
    'a stalled server degrades to unknown within cap + 100ms',
    () async {
      server.listen((request) {
        // Deliberately never respond -- a dead/hung provider.
      });

      final stopwatch = Stopwatch()..start();
      final verdict = await StreamKindProbe.probe('$baseUrl/stall', null);
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

      final verdict = await StreamKindProbe.probe('$baseUrl/live.m3u8', null);

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

    final verdict = await StreamKindProbe.probe(
      'http://127.0.0.1:$refusedPort/nothing-here',
      null,
    );

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

      final verdict = await StreamKindProbe.probe('$baseUrl/loop', null);

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

      final verdict = await StreamKindProbe.probe(
        'http://127.0.0.1:${rawServer.port}/garbage',
        null,
      );

      expect(verdict, StreamKindVerdict.unknown);
    },
  );
}
