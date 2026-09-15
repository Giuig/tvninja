import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'stream_format_hint.dart';

/// Pre-resolves a redirect/relinker-style stream URL to the real playlist URL
/// before handing it to a playback engine.
///
/// ## Why this exists
///
/// Some providers put an access-control servlet in front of the stream rather
/// than publishing a playlist URL directly — RAI's
/// `mediapolis.rai.it/relinker/relinkerServlet.htm?cont=...` is the case that
/// motivated this. Fetching that URL yields a 302 to a short-lived tokenised
/// CDN playlist; the real `.m3u8` never appears in the channel list.
///
/// Android's ExoPlayer path (`video_player_android`'s `DefaultHttpDataSource`,
/// `HttpURLConnection`/Conscrypt-backed) is refused by that servlet with a
/// **403**, while `dart:io`'s `HttpClient` (Dart VM's bundled BoringSSL) gets
/// through. Measured on-device (BlueStacks, 2026-09-15) on the identical URL
/// within 2.5 seconds of each other: Dart 200 + real `#EXTM3U`, ExoPlayer
/// `InvalidResponseCodeException: Response code: 403`.
///
/// The cause is *not* the User-Agent. A UA matrix run over the Dart stack
/// returned 200 for every candidate including media3's own default
/// (`AndroidXMedia3/1.9.2 (Linux;Android 9) ...`), for `raiplayappletv`, for a
/// desktop Chrome UA and for no UA at all — only `VLC/3.0.20 LibVLC/3.0.20`
/// drew a 403, proving the servlet runs a UA blocklist that media3 simply
/// isn't on. So swapping ExoPlayer's UA would not have helped; the difference
/// is the HTTP/TLS stack itself (never packet-captured, so the precise
/// discriminator is still unproven — but it is demonstrably not the UA).
///
/// Resolving here, on Dart's stack, sidesteps it generically: ExoPlayer only
/// ever sees the already-resolved CDN URL, which it fetches normally. This
/// replaces the earlier `_exoBlockedUrlPatterns` hostname carve-out (which
/// forced RAI onto `MpvEngine`) — that needed a source edit + release per
/// affected provider and had already been widened once within a single
/// session.
///
/// ## Scope and cost
///
/// Only URLs that [guessStreamFormat] can't classify are resolved — i.e. no
/// `.m3u8`/`.ts`/`.mp4` suffix, which in this app's channel list is
/// overwhelmingly a relinker/redirect-style service. A direct CDN playlist URL
/// is returned untouched and costs nothing. A resolved URL therefore adds one
/// extra round trip (~100-600ms measured) only to the channels that need it.
///
/// Every failure mode — non-200, timeout, no redirect at all, a malformed
/// `Location` — returns [url] unchanged, so this can never make a channel less
/// playable than it was before resolution existed.
class StreamUrlResolver {
  StreamUrlResolver._();

  /// Total budget for the whole resolve attempt — connection setup *and* the
  /// redirect chain. Deliberately well under
  /// `UnifiedVideoPlayerState._initializePlayer`'s own 10s `open()` timeout so
  /// a slow relinker degrades to "play the original URL" rather than eating
  /// the whole open budget and surfacing as a timeout.
  ///
  /// This wraps [_follow] in its entirety rather than just the response. An
  /// earlier version timed only `request.close()`, leaving `client.getUrl()`
  /// bounded solely by [_connectTimeout] — so the real worst case was
  /// connect + response ≈ 11s, over the caller's 10s budget rather than
  /// under it. Since `.timeout()` on the caller's side cannot cancel
  /// `_createAndOpen` (see `exo_engine.dart`), overshooting here would trip
  /// that outer timeout and kick off a needless reconnect for a relinker that
  /// was merely slow, not broken — the exact failure this budget exists to
  /// prevent.
  static const Duration _timeout = Duration(seconds: 6);

  /// Bounds connection setup alone. Kept under [_timeout] so it can only ever
  /// fire *within* the total budget, never extend it.
  static const Duration _connectTimeout = Duration(seconds: 4);

  /// Follows [url]'s redirect chain and returns the final URL, or [url]
  /// unchanged if it doesn't need resolving or resolution fails.
  ///
  /// [headers] is the same `User-Agent` map the engine will play with, so the
  /// resolve request is made under the same identity as playback — providers
  /// that vary their response by UA hand back the URL playback will actually
  /// use.
  static Future<String> resolve(String url, Map<String, String>? headers) async {
    if (guessStreamFormat(url) != StreamFormatHint.unknown) return url;

    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final resolved = await _follow(client, url, headers).timeout(_timeout);
      if (resolved == null) return url;
      debugPrint('[StreamUrlResolver] $url -> $resolved');
      return resolved;
    } catch (e) {
      debugPrint('[StreamUrlResolver] resolve failed for $url: $e');
      return url;
    } finally {
      // The body is deliberately never read — only the redirect chain matters,
      // and the engine is about to fetch the playlist itself. force: true
      // drops the still-open response socket instead of leaking it: a plain
      // close() waits for the connection to fall idle, which an undrained
      // response may never do.
      client.close(force: true);
    }
  }

  /// Follows [url]'s redirect chain and returns the final URL, or `null` if
  /// there is nothing worth rewriting. Split out so [resolve]'s single
  /// `.timeout(_timeout)` covers connection setup as well as the response.
  static Future<String?> _follow(
    HttpClient client,
    String url,
    Map<String, String>? headers,
  ) async {
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    request.maxRedirects = 10;
    headers?.forEach(request.headers.set);
    final response = await request.close();

    if (response.statusCode != 200 || response.redirects.isEmpty) {
      // Either the URL was already final (nothing gained by rewriting it) or
      // the provider refused us too — in both cases let the engine make its
      // own attempt rather than substituting a URL we don't trust.
      return null;
    }

    // `RedirectInfo.location` is the raw, possibly-relative `Location` header
    // of that hop — `dart:io` does not write its own resolved absolute URI
    // back onto it. So each hop must be resolved against the *previous*
    // resolved hop (the running `resolved` below), mirroring dart:io's own
    // per-hop base. Resolving every hop against the original `url` instead
    // would produce the wrong final URL for any chain with a relative
    // `Location` beyond the first hop.
    var resolved = Uri.parse(url);
    for (final redirect in response.redirects) {
      resolved = resolved.resolveUri(redirect.location);
    }
    return resolved.toString();
  }
}
