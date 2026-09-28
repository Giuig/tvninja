import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'stream_format_hint.dart';
import 'stream_kind.dart';

/// Probes a channel's stream URL once, off the open path, and returns a
/// [StreamKindVerdict] — never a raw exception, never a hang past its own
/// budget.
///
/// ## What it reads, and why so little
///
/// A non-HLS decision only ever needs the response headers (`Content-Type`,
/// `icy-*`) — [classifyResponseHeaders] settles it with zero body bytes. Only
/// when the response looks like an HLS playlist (by `Content-Type` or the
/// URL's own suffix) is the body worth reading at all, and even then only
/// [_maxBodyBytes] of it: `EXT-X-STREAM-INF`/`EXTINF` lines are always near
/// the top of a real playlist, so a capped read is enough for
/// [classifyHlsPlaylist] without downloading a whole media playlist's segment
/// list.
///
/// ## Budget
///
/// [_cap] is the whole attempt's wall-clock budget, connection setup
/// included — measured against 20 real audio and 30 real video census
/// entries (p50 197ms, p95 861ms, max 928ms), it has headroom to spare. A cap
/// hit degrades to [StreamKindVerdict.unknown], which opens as video exactly
/// like today, so a slow or stalled probe can never make a channel less
/// playable than it already was.
class StreamKindProbe {
  StreamKindProbe._();

  static const Duration _cap = Duration(milliseconds: 1200);
  static const Duration _connectTimeout = Duration(milliseconds: 800);
  static const int _maxBodyBytes = 64 * 1024;

  /// Probes [url] and returns a verdict. [headers] should be the same map
  /// playback will use (its User-Agent), so a UA-gated provider answers the
  /// probe the way it will answer playback.
  static Future<StreamKindVerdict> probe(
    String url,
    Map<String, String>? headers,
  ) async {
    if (kIsWeb) return StreamKindVerdict.unknown;

    final stopwatch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final verdict = await _probe(client, url, headers).timeout(_cap);
      _log(url, verdict, stopwatch);
      return verdict;
    } catch (e) {
      // Every failure -- a timeout, a refused connection, a malformed HTTP
      // response, a redirect loop past maxRedirects -- degrades to unknown
      // rather than being read as evidence of anything. A broken response is
      // not proof of audio: a TV channel behind a looping or malfunctioning
      // relinker would otherwise get misread as a legacy audio server and
      // locked into audio mode for 30 days by exactly the kind of failure
      // that says nothing about what the stream actually carries.
      _log(url, StreamKindVerdict.unknown, stopwatch, error: e);
      return StreamKindVerdict.unknown;
    } finally {
      // The playlist body (if any was read at all) is deliberately left
      // undrained -- only a capped prefix matters here, and the engine is
      // about to fetch the real thing. force: true drops the socket instead
      // of waiting for a live stream to fall idle, which it never would.
      client.close(force: true);
    }
  }

  static Future<StreamKindVerdict> _probe(
    HttpClient client,
    String url,
    Map<String, String>? headers,
  ) async {
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    request.maxRedirects = 10;
    headers?.forEach(request.headers.set);
    final response = await request.close();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return StreamKindVerdict.unknown;
    }

    final contentType = response.headers.value('content-type');
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) responseHeaders[name] = values.first;
    });

    final headerVerdict = classifyResponseHeaders(
      contentType: contentType,
      headers: responseHeaders,
    );
    if (headerVerdict.kind != StreamKind.unknown) {
      return headerVerdict;
    }

    final looksLikeHls = (contentType != null && isHlsMime(contentType)) ||
        guessStreamFormat(url) == StreamFormatHint.hls;
    if (!looksLikeHls) {
      return StreamKindVerdict.unknown;
    }

    final body = await _readCappedBody(response, _maxBodyBytes);
    return classifyHlsPlaylist(body);
  }

  /// Reads up to [maxBytes] of [response]'s body and decodes it as text,
  /// stopping as soon as the cap is reached rather than draining the whole
  /// stream -- a media playlist can carry hundreds of segments, and only the
  /// leading `EXT-X-STREAM-INF`/`EXTINF` lines are ever needed.
  ///
  /// When the cap cuts the read short, the trailing partial line is dropped
  /// -- a segment URI split mid-filename by the cap would otherwise look
  /// unrecognisable to [classifyHlsPlaylist] and drag an otherwise-clean
  /// all-audio playlist down to unknown.
  static Future<String> _readCappedBody(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    final bytes = <int>[];
    var truncated = false;
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) {
        truncated = true;
        break;
      }
    }
    final capped = bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes;
    var text = utf8.decode(capped, allowMalformed: true);
    if (truncated) {
      final lastNewline = text.lastIndexOf('\n');
      if (lastNewline != -1) text = text.substring(0, lastNewline);
    }
    return text;
  }

  static void _log(
    String url,
    StreamKindVerdict verdict,
    Stopwatch stopwatch, {
    Object? error,
  }) {
    final ms = stopwatch.elapsedMilliseconds;
    if (error != null) {
      debugPrint('[StreamKind] $url -> $verdict (${ms}ms, probe failed: $error)');
    } else {
      debugPrint('[StreamKind] $url -> $verdict (${ms}ms)');
    }
  }
}
