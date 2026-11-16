import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_kind.dart';

/// Pure classification logic, no network. Fixtures are shaped after the
/// actual playlists a published-playlist census measured, so a regression
/// here is a regression against a real stream, not a synthetic edge case.
void main() {
  group('classifyResponseHeaders', () {
    test('an audio/* Content-Type is strong audio', () {
      final verdict = classifyResponseHeaders(
        contentType: 'audio/aacp',
        headers: const {},
      );
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.source, KindSource.contentType);
      expect(verdict.locksAudio, isTrue);
    });

    test('an icy-* header with no usable Content-Type is strong audio', () {
      final verdict = classifyResponseHeaders(
        contentType: null,
        headers: const {'icy-name': 'Test Radio'},
      );
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.source, KindSource.icyHeader);
    });

    test('icy-* header detection is case-insensitive', () {
      final verdict = classifyResponseHeaders(
        contentType: null,
        headers: const {'ICY-Br': '128'},
      );
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.source, KindSource.icyHeader);
    });

    test('a video/* Content-Type is video', () {
      final verdict = classifyResponseHeaders(
        contentType: 'video/mp2t',
        headers: const {},
      );
      expect(verdict.kind, StreamKind.video);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.locksAudio, isFalse);
    });

    test('an HLS Content-Type is neither -- unknown, left to the playlist classifier', () {
      final verdict = classifyResponseHeaders(
        contentType: 'application/vnd.apple.mpegurl',
        headers: const {},
      );
      expect(verdict.kind, StreamKind.unknown);
      expect(verdict.locksAudio, isFalse);
    });

    test('no signal at all is unknown', () {
      final verdict = classifyResponseHeaders(contentType: null, headers: const {});
      expect(verdict, StreamKindVerdict.unknown);
    });
  });

  group('classifyHlsPlaylist -- master playlists', () {
    test('Radio 24: low-bandwidth audio-only CODECS is strong audio', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=67171,CODECS="mp4a.40.5"\n'
          'audio/playlist.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.source, KindSource.hlsMasterCodecs);
      expect(verdict.locksAudio, isTrue);
    });

    test('a BBC-style 320 kbps audio-only master is still strong audio', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS="mp4a.40.2"\n'
          'bbc_radio_three-audio=320000.norewind.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
    });

    test(
      'LaC News 24: audio-only CODECS at 3.5 Mbps on every variant is provisional, not strong',
      () {
        const playlist = '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=3538000,CODECS="mp4a.40.2"\n'
            'variant1/playlist.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=3538000,CODECS="mp4a.40.2"\n'
            'variant2/playlist.m3u8\n';
        final verdict = classifyHlsPlaylist(playlist);
        expect(verdict.kind, StreamKind.audioOnly);
        expect(verdict.confidence, KindConfidence.provisional);
        // The load-bearing assertion: a provisional verdict never locks
        // audio mode, so this real TV channel still opens as video.
        expect(verdict.locksAudio, isFalse);
      },
    );

    test('a RESOLUTION attribute means video, even alongside audio CODECS', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          'variant.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.video);
      expect(verdict.locksAudio, isFalse);
    });

    test('a video codec in CODECS means video, even with no RESOLUTION', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'variant.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.video);
    });

    test('an EXT-X-MEDIA:TYPE=VIDEO rendition means video', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="vid",NAME="main"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS="mp4a.40.2"\n'
          'variant.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.video);
    });

    test('a mixed master with a video variant is video, not partial audio', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"\n'
          'high.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.5"\n'
          'audio_only.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.video);
    });

    test('a master with no CODECS attribute at all is unknown', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
          'variant.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.unknown);
    });

    test('an all-audio-CODECS master with no BANDWIDTH anywhere is unknown', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:CODECS="mp4a.40.2"\n'
          'variant.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.unknown);
    });
  });

  group('classifyHlsPlaylist -- media playlists', () {
    test('packed-audio segments (.aac) are strong audio', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXTINF:10.0,\n'
          'segment1.aac\n'
          '#EXTINF:10.0,\n'
          'segment2.aac\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.source, KindSource.hlsMediaPlaylist);
      expect(verdict.locksAudio, isTrue);
    });

    test('a bare .ts media playlist is unknown', () {
      const playlist = '#EXTM3U\n'
          '#EXTINF:10.0,\n'
          'segment1.ts\n'
          '#EXTINF:10.0,\n'
          'segment2.ts\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.unknown);
    });

    test('a .m4s media playlist is unknown', () {
      const playlist = '#EXTM3U\n'
          '#EXTINF:6.0,\n'
          'init.mp4\n'
          '#EXTINF:6.0,\n'
          'segment1.m4s\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.unknown);
    });

    test('an empty media playlist is unknown', () {
      const playlist = '#EXTM3U\n#EXT-X-ENDLIST\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.unknown);
    });
  });
}
