import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';
import 'package:tvninja/services/video/stream_kind_classifier.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
  });

  test('radio=true is answered by peek() with no network at all', () {
    // A channel URL nothing listens on -- if classify() ever reached the
    // network, this would hang or refuse rather than resolve instantly.
    final channel = Channel(
      name: 'Soffitta Radio',
      url: 'http://127.0.0.1:1/unreachable',
      isRadio: true,
    );

    final verdict = StreamKindClassifier.peek(channel);

    expect(verdict?.kind, StreamKind.audioOnly);
    expect(verdict?.confidence, KindConfidence.strong);
    expect(verdict?.source, KindSource.radioAttribute);
  });

  test('classify() on a radio=true channel resolves synchronously, no probe', () async {
    final channel = Channel(
      name: 'Soffitta Radio',
      url: 'http://127.0.0.1:1/unreachable',
      isRadio: true,
    );

    final stopwatch = Stopwatch()..start();
    final verdict = await StreamKindClassifier.classify(channel);
    stopwatch.stop();

    expect(verdict.kind, StreamKind.audioOnly);
    expect(verdict.source, KindSource.radioAttribute);
    // The probe's own connect timeout alone is 800ms; resolving in well
    // under that proves the network was never touched.
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('a cache hit short-circuits classify() with no probe', () async {
    final channel = Channel(
      name: 'Cached Channel',
      url: 'http://127.0.0.1:1/unreachable-but-cached',
    );
    StreamKindCache.put(
      channel.uniqueId,
      const StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.contentType,
      ),
    );

    final stopwatch = Stopwatch()..start();
    final verdict = await StreamKindClassifier.classify(channel);
    stopwatch.stop();

    expect(verdict.kind, StreamKind.audioOnly);
    expect(verdict.source, KindSource.contentType);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('an uncached, non-radio channel probes and the result is cached', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.set('content-type', 'audio/aacp')
        ..statusCode = 200
        ..close();
    });

    final channel = Channel(
      name: 'Real Station',
      url: 'http://${server.address.address}:${server.port}/stream',
    );

    final first = await StreamKindClassifier.classify(channel);
    expect(first.kind, StreamKind.audioOnly);
    expect(first.source, KindSource.contentType);

    // A second call must be a cache hit, not a second probe -- proven by
    // shutting the server down first.
    await server.close(force: true);
    final second = await StreamKindClassifier.classify(channel);
    expect(second, first);
  });

  test('concurrent classify() calls for the same channel coalesce into one probe', () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestCount++;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      request.response
        ..headers.set('content-type', 'audio/mpeg')
        ..statusCode = 200
        ..close();
    });

    final channel = Channel(
      name: 'Slow Station',
      url: 'http://${server.address.address}:${server.port}/stream',
    );

    final results = await Future.wait([
      StreamKindClassifier.classify(channel),
      StreamKindClassifier.classify(channel),
      StreamKindClassifier.classify(channel),
    ]);

    expect(requestCount, 1);
    expect(results[0].kind, StreamKind.audioOnly);
    expect(results[1], results[0]);
    expect(results[2], results[0]);
  });
}
