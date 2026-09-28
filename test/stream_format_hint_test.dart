import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_format_hint.dart';

/// Pins the suffix and MIME tables `guessStreamFormat`/`formatHintFromContentType`
/// use to decide how a stream gets opened. `audio/mpegurl` and
/// `audio/x-mpegurl` are the one deliberately counter-intuitive entry: they
/// look like progressive audio because of the `audio/` prefix, but they're a
/// real alias some servers use for an HLS playlist, so they must resolve to
/// `hls`, not `audio`. A regression there would mean an HLS playlist gets
/// handed to a progressive decoder, which cannot parse it.
void main() {
  group('guessStreamFormat: suffix table', () {
    final cases = <String, StreamFormatHint>{
      'https://example.com/live/channel.m3u8': StreamFormatHint.hls,
      'https://example.com/live/channel.m3u8?token=abc': StreamFormatHint.hls,
      'https://example.com/live/segment.ts': StreamFormatHint.mpegTs,
      'https://example.com/live/segment.ts?t=1': StreamFormatHint.mpegTs,
      'https://example.com/vod/movie.mp4': StreamFormatHint.mp4,
      'https://example.com/vod/movie.mp4?t=1': StreamFormatHint.mp4,
      'https://example.com/stream.mp3': StreamFormatHint.audio,
      'https://example.com/stream.aac': StreamFormatHint.audio,
      'https://example.com/stream.m4a': StreamFormatHint.audio,
      'https://example.com/stream.ogg': StreamFormatHint.audio,
      'https://example.com/stream.opus': StreamFormatHint.audio,
      'https://example.com/stream.flac': StreamFormatHint.audio,
      'https://example.com/stream.mp3?session=1': StreamFormatHint.audio,
      'https://example.com/stream': StreamFormatHint.unknown,
      'https://mediapolis.rai.it/relinker/relinkerServlet.htm?cont=395276':
          StreamFormatHint.unknown,
      'https://EXAMPLE.com/STREAM.MP3': StreamFormatHint.audio,
    };

    cases.forEach((url, expected) {
      test('$url -> $expected', () {
        expect(guessStreamFormat(url), expected);
      });
    });
  });

  group('isHlsMime', () {
    for (final mime in [
      'application/vnd.apple.mpegurl',
      'application/x-mpegurl',
      'audio/mpegurl',
      'audio/x-mpegurl',
      'APPLICATION/VND.APPLE.MPEGURL',
      'application/vnd.apple.mpegurl; charset=utf-8',
    ]) {
      test('$mime is HLS', () => expect(isHlsMime(mime), isTrue));
    }

    for (final mime in ['audio/mpeg', 'audio/aac', 'video/mp4', 'text/plain']) {
      test('$mime is not HLS', () => expect(isHlsMime(mime), isFalse));
    }
  });

  group('isProgressiveAudioMime', () {
    for (final mime in ['audio/mpeg', 'audio/aac', 'audio/aacp', 'audio/mp4', 'AUDIO/OGG']) {
      test('$mime is progressive audio', () => expect(isProgressiveAudioMime(mime), isTrue));
    }

    // The HLS aliases carry the audio/ prefix but must not count as
    // progressive audio -- a playlist can't be handed to a progressive decoder.
    for (final mime in ['audio/mpegurl', 'audio/x-mpegurl', 'video/mp4', 'text/plain']) {
      test('$mime is not progressive audio', () => expect(isProgressiveAudioMime(mime), isFalse));
    }
  });

  group('isProgressiveVideoMime', () {
    for (final mime in ['video/mp4', 'video/mp2t', 'VIDEO/MP4']) {
      test('$mime is progressive video', () => expect(isProgressiveVideoMime(mime), isTrue));
    }

    for (final mime in ['audio/mpeg', 'application/x-mpegurl', 'text/plain']) {
      test('$mime is not progressive video', () => expect(isProgressiveVideoMime(mime), isFalse));
    }
  });

  group('formatHintFromContentType', () {
    final cases = <String?, StreamFormatHint>{
      null: StreamFormatHint.unknown,
      '': StreamFormatHint.unknown,
      'application/vnd.apple.mpegurl': StreamFormatHint.hls,
      'application/x-mpegurl': StreamFormatHint.hls,
      'audio/mpegurl': StreamFormatHint.hls,
      'audio/x-mpegurl': StreamFormatHint.hls,
      'audio/mpeg': StreamFormatHint.audio,
      'audio/aac': StreamFormatHint.audio,
      'audio/aacp': StreamFormatHint.audio,
      'audio/mpeg; charset=utf-8': StreamFormatHint.audio,
      'video/mp4': StreamFormatHint.mp4,
      'video/mp2t': StreamFormatHint.mpegTs,
      'text/html': StreamFormatHint.unknown,
      'application/octet-stream': StreamFormatHint.unknown,
    };

    cases.forEach((contentType, expected) {
      test('${contentType ?? 'null'} -> $expected', () {
        expect(formatHintFromContentType(contentType), expected);
      });
    });
  });
}
