import 'dart:async';

import 'package:tvninja/config/config.dart';

import 'stream_kind.dart';
import 'stream_kind_cache.dart';
import 'stream_kind_probe.dart';

/// The single entry point a caller should use to learn a channel's stream
/// kind -- ties [Channel.isRadio], [StreamKindCache] and [StreamKindProbe]
/// together so nothing else needs to know the order they're consulted in.
class StreamKindClassifier {
  StreamKindClassifier._();

  static final Map<String, Future<StreamKindVerdict>> _inFlight = {};

  /// A synchronous, zero-network best-effort answer: `radio="true"` first
  /// (an instant strong signal, needing no probe at all), then a cache hit.
  /// Returns `null` when neither is available, meaning the caller has to
  /// fall back to [classify].
  static StreamKindVerdict? peek(Channel channel) {
    if (channel.isRadio) {
      return const StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.radioAttribute,
      );
    }
    return StreamKindCache.get(channel.uniqueId);
  }

  /// Resolves [channel]'s stream kind, preferring [peek] and probing only on
  /// a miss. Concurrent calls for the same channel -- rapid zapping back to
  /// a channel still being probed, for instance -- share the one in-flight
  /// probe rather than firing a second request.
  static Future<StreamKindVerdict> classify(Channel channel) {
    final immediate = peek(channel);
    if (immediate != null) return Future.value(immediate);

    return _inFlight.putIfAbsent(
      channel.uniqueId,
      () => _probeAndCache(channel),
    );
  }

  static Future<StreamKindVerdict> _probeAndCache(Channel channel) async {
    try {
      final verdict = await StreamKindProbe.probe(channel.url, _headersFor(channel));
      StreamKindCache.put(channel.uniqueId, verdict);
      return verdict;
    } finally {
      _inFlight.remove(channel.uniqueId);
    }
  }

  static Map<String, String>? _headersFor(Channel channel) {
    final userAgent = channel.userAgent;
    if (userAgent == null || userAgent.isEmpty) return null;
    return {'User-Agent': userAgent};
  }
}
