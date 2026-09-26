import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// What a diagnostic probe of a stream URL concluded.
///
/// [ok] and [unknown] both mean "don't override the caller's message" — they
/// are distinct only so the caller can log the difference.
enum StreamProbeResult {
  /// The URL answered 2xx. Whatever failed, it wasn't a dead or gated URL.
  ok,

  /// 404 — the stream is gone.
  notFound,

  /// 403 — reachable but refused.
  forbidden,

  /// 401 — credentials required.
  unauthorized,

  /// 5xx — the origin is broken rather than the stream.
  serverError,

  /// Couldn't reach the host at all (DNS, TCP, TLS, timeout).
  networkError,

  /// Probe was skipped or returned something unclassifiable.
  unknown,
}

/// Works out *why* playback failed, by asking the network directly.
///
/// ## Why this exists
///
/// On Android, `video_player_android`'s `ExoPlayerEventListener.onPlayerError`
/// reports only `"Video player had error " + PlaybackException.toString()`.
/// For the whole `TYPE_SOURCE` category — every HTTP failure, i.e. exactly the
/// ones worth telling a user about — `ExoPlaybackException`'s derived message
/// is the hardcoded literal `"Source error"`: no status code, no
/// `errorCodeName`, no cause text. Verified against the pinned
/// `video_player_android 2.9.5` in the pub cache, not inferred.
///
/// So a 404, a 403 and a DNS failure all reach Dart as the byte-identical
/// string `"Video player had error androidx.media3.exoplayer.
/// ExoPlaybackException: Source error"`. No amount of substring matching on
/// that can tell them apart — before this class, all three collapsed to a
/// generic message, losing the specific 404/403/network wording the mpv path
/// had always produced. That's a real regression introduced by the ExoPlayer
/// migration, and it affects every Android user.
///
/// Rather than fork the plugin or add a platform channel to surface
/// `errorCode`, this re-requests the URL on Dart's own HTTP stack (the same
/// stack `StreamUrlResolver` already relies on) and reads the status code the
/// engine wouldn't tell us. Engine-agnostic, and more accurate than
/// error-string matching ever was: it reports what the server says *now*.
///
/// ## Deliberate limits
///
/// - Runs only on an already-failed load, so the extra request costs nothing
///   in the normal case.
/// - [ok] is a real possible answer and must never be treated as "no error":
///   the two stacks genuinely disagree sometimes (RAI's relinker 403'd
///   ExoPlayer while answering 200 to Dart in the same second). Callers keep
///   their original message in that case rather than claiming success.
/// - Never throws. Every failure path returns a value.
class StreamDiagnostics {
  StreamDiagnostics._();

  static const Duration _timeout = Duration(seconds: 4);
  static const Duration _connectTimeout = Duration(seconds: 3);

  /// Probes [url] and reports what the server said. [headers] should be the
  /// same map playback used, so a UA-gated provider answers the probe the way
  /// it answered playback.
  static Future<StreamProbeResult> probe(
    String url,
    Map<String, String>? headers,
  ) async {
    if (kIsWeb) return StreamProbeResult.unknown;

    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final status = await _statusOf(client, url, headers).timeout(_timeout);
      final result = _classify(status);
      debugPrint('[StreamDiagnostics] $url -> HTTP $status ($result)');
      return result;
    } on TimeoutException {
      debugPrint('[StreamDiagnostics] $url -> timed out');
      return StreamProbeResult.networkError;
    } on SocketException {
      debugPrint('[StreamDiagnostics] $url -> unreachable');
      return StreamProbeResult.networkError;
    } on HandshakeException {
      debugPrint('[StreamDiagnostics] $url -> TLS failure');
      return StreamProbeResult.networkError;
    } catch (e) {
      debugPrint('[StreamDiagnostics] $url -> probe failed: $e');
      return StreamProbeResult.unknown;
    } finally {
      // Body is never read — only the status line matters. force: true drops
      // the socket instead of waiting for a live stream to fall idle, which
      // it never would.
      client.close(force: true);
    }
  }

  static Future<int> _statusOf(
    HttpClient client,
    String url,
    Map<String, String>? headers,
  ) async {
    // GET, not HEAD: plenty of streaming origins reject or mishandle HEAD and
    // would report a misleading 405 for a perfectly healthy stream.
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    request.maxRedirects = 10;
    headers?.forEach(request.headers.set);
    final response = await request.close();
    return response.statusCode;
  }

  /// The user-facing message for [result], or null when the caller should
  /// keep its own fallback ([StreamProbeResult.ok], [StreamProbeResult.serverError],
  /// [StreamProbeResult.unknown]).
  ///
  /// Shared by the video path (`UnifiedVideoPlayer._surfaceError`) and the
  /// native audio path (`NativeAudioService`), so both report a dead stream in
  /// the same words. The wording is load-bearing: `player_page.dart`'s
  /// `_errorIcon()` string-matches it to pick an icon.
  static String? userMessage(StreamProbeResult result) => switch (result) {
        StreamProbeResult.notFound => 'Stream not found (404)',
        StreamProbeResult.forbidden => 'Access denied (403)',
        StreamProbeResult.unauthorized => 'Authentication required (401)',
        StreamProbeResult.networkError =>
          'Network error — check your connection',
        StreamProbeResult.serverError ||
        StreamProbeResult.ok ||
        StreamProbeResult.unknown =>
          null,
      };

  /// Whether [result] means retrying the same URL cannot help: the server
  /// answered, and the answer was no.
  static bool isPermanent(StreamProbeResult result) =>
      result == StreamProbeResult.notFound ||
      result == StreamProbeResult.forbidden ||
      result == StreamProbeResult.unauthorized;

  static StreamProbeResult _classify(int status) {
    if (status == 404) return StreamProbeResult.notFound;
    if (status == 403) return StreamProbeResult.forbidden;
    if (status == 401) return StreamProbeResult.unauthorized;
    if (status >= 500) return StreamProbeResult.serverError;
    if (status >= 200 && status < 300) return StreamProbeResult.ok;
    return StreamProbeResult.unknown;
  }
}
