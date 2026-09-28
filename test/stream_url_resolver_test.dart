import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_url_resolver.dart';

/// Exercises `StreamUrlResolver.resolve` against a real loopback
/// `HttpServer` -- the redirect-following, content-type-reading and
/// timeout-recovery behaviour all depend on dart:io's actual `HttpClient`,
/// which nothing else in this suite touches. Every test URL is suffix-less
/// on purpose, so `resolve` always makes the GET instead of short-circuiting.
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

  test('a direct 200 response keeps its Content-Type with no URL change', () async {
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'audio/mpeg')
        ..statusCode = 200
        ..write('ignored')
        ..close();
    });

    final result = await StreamUrlResolver.resolve('$baseUrl/stream', null);

    // A bare Icecast-style stream: never redirects, but the Content-Type
    // header from this one GET is exactly what the audio format hint needs.
    expect(result.url, '$baseUrl/stream');
    expect(result.contentType, 'audio/mpeg');
  });

  test('a 302 redirect to a real playlist is followed and its Content-Type kept', () async {
    server.listen((request) {
      if (request.uri.path == '/relinker') {
        request.response
          ..statusCode = 302
          ..headers.set('location', '$baseUrl/live/channel.m3u8')
          ..close();
      } else {
        request.response
          ..headers.set('content-type', 'application/vnd.apple.mpegurl')
          ..statusCode = 200
          ..write('#EXTM3U')
          ..close();
      }
    });

    final result = await StreamUrlResolver.resolve('$baseUrl/relinker', null);

    expect(result.url, '$baseUrl/live/channel.m3u8');
    expect(result.contentType, 'application/vnd.apple.mpegurl');
  });

  test('a 403 is an outright refusal -- original URL, no content type', () async {
    server.listen((request) {
      request.response
        ..statusCode = 403
        ..close();
    });

    final result = await StreamUrlResolver.resolve('$baseUrl/blocked', null);

    expect(result.url, '$baseUrl/blocked');
    expect(result.contentType, isNull);
  });

  test(
    'a stalled server falls back to the original URL within the resolve budget',
    () async {
      server.listen((request) {
        // Deliberately never write a response -- simulates a server that
        // accepts the connection and then hangs, which is exactly what a
        // dead relinker looks like on the wire.
      });

      final stopwatch = Stopwatch()..start();
      final result = await StreamUrlResolver.resolve('$baseUrl/stall', null);
      stopwatch.stop();

      expect(result.url, '$baseUrl/stall');
      expect(result.contentType, isNull);
      // resolve()'s own budget is 6s -- headroom above that for the loopback
      // round trip, well short of "hangs indefinitely" (the failure this
      // guards against).
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
