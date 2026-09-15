/// Container format guessed from a stream URL's path suffix.
///
/// Shared between both playback engines (Phase 3) so the same suffix-
/// matching logic backs mpv's `demuxer-lavf-format` hint
/// (`mpv_options.dart`'s `applyFormatHint`) and ExoPlayer's `VideoFormat`
/// hint (`engines/exo_engine.dart`) — each engine maps this to its own
/// format identifier rather than duplicating the string matching.
enum StreamFormatHint { hls, mpegTs, mp4, unknown }

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
  return StreamFormatHint.unknown;
}
