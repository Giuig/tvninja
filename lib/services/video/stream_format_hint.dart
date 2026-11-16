/// Container format guessed from a stream URL's path suffix, or — when the
/// URL has none — from the response's `Content-Type` header.
///
/// Shared between both playback engines so the same suffix-
/// matching logic backs mpv's `demuxer-lavf-format` hint
/// (`mpv_options.dart`'s `applyFormatHint`) and ExoPlayer's `VideoFormat`
/// hint (`engines/exo_engine.dart`) — each engine maps this to its own
/// format identifier rather than duplicating the string matching.
enum StreamFormatHint { hls, mpegTs, mp4, audio, unknown }

/// Suffixes recognised as a bare progressive-audio stream (no container
/// negotiation needed — a plain MP3/AAC/etc. byte stream from an Icecast- or
/// Shoutcast-style source).
const List<String> _audioSuffixes = ['.mp3', '.aac', '.m4a', '.ogg', '.opus', '.flac'];

/// Infers [StreamFormatHint] from [url]'s path, or [StreamFormatHint.unknown]
/// if ambiguous. Synchronous and side-effect-free.
StreamFormatHint guessStreamFormat(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  if (path.endsWith('.m3u8') || path.contains('.m3u8?')) {
    return StreamFormatHint.hls;
  }
  if (path.endsWith('.ts') || path.contains('.ts?')) {
    return StreamFormatHint.mpegTs;
  }
  if (path.endsWith('.mp4') || path.contains('.mp4?')) {
    return StreamFormatHint.mp4;
  }
  for (final suffix in _audioSuffixes) {
    if (path.endsWith(suffix) || path.contains('$suffix?')) {
      return StreamFormatHint.audio;
    }
  }
  return StreamFormatHint.unknown;
}

/// Strips a `; charset=...`-style parameter and surrounding whitespace, and
/// lower-cases what's left, so every MIME check below compares on the bare
/// `type/subtype` alone.
String _normalizedMime(String contentType) {
  final semicolon = contentType.indexOf(';');
  final bare = semicolon == -1 ? contentType : contentType.substring(0, semicolon);
  return bare.trim().toLowerCase();
}

/// Whether [contentType] names an HLS playlist.
///
/// `audio/mpegurl` and `audio/x-mpegurl` belong here too, even though the
/// `audio/` prefix looks like it should mean [isProgressiveAudioMime] —
/// they're a real (if less common) alias some servers use for the same
/// `#EXTM3U` playlist as `application/vnd.apple.mpegurl`, and a playlist can't
/// be handed to a progressive decoder. This check must run before
/// [isProgressiveAudioMime] for that reason.
bool isHlsMime(String contentType) {
  final mime = _normalizedMime(contentType);
  return mime == 'application/vnd.apple.mpegurl' ||
      mime == 'application/x-mpegurl' ||
      mime == 'audio/mpegurl' ||
      mime == 'audio/x-mpegurl';
}

/// Whether [contentType] names a plain progressive audio byte stream (an
/// Icecast/Shoutcast-style `audio/mpeg`, `audio/aac`, `audio/aacp`, etc.) —
/// any `audio/*` MIME that isn't one of the HLS aliases above.
bool isProgressiveAudioMime(String contentType) {
  if (isHlsMime(contentType)) return false;
  return _normalizedMime(contentType).startsWith('audio/');
}

/// Whether [contentType] names a plain progressive video container
/// (`video/mp4`, `video/mp2t`, ...).
bool isProgressiveVideoMime(String contentType) {
  return _normalizedMime(contentType).startsWith('video/');
}

/// Maps a response's `Content-Type` header to a [StreamFormatHint], for URLs
/// whose path carries no recognisable suffix of its own — `StreamUrlResolver`
/// captures this from the GET it already makes to follow relinker/redirect
/// chains, so reading it here costs no extra request. Returns
/// [StreamFormatHint.unknown] for `null`/empty input or anything not covered
/// above; callers keep their own suffix-first fallback for that case.
StreamFormatHint formatHintFromContentType(String? contentType) {
  if (contentType == null || contentType.isEmpty) return StreamFormatHint.unknown;
  if (isHlsMime(contentType)) return StreamFormatHint.hls;
  if (isProgressiveAudioMime(contentType)) return StreamFormatHint.audio;
  if (isProgressiveVideoMime(contentType)) {
    return _normalizedMime(contentType) == 'video/mp2t'
        ? StreamFormatHint.mpegTs
        : StreamFormatHint.mp4;
  }
  return StreamFormatHint.unknown;
}
