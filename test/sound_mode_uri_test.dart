import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_kind.dart';

/// Pure selection logic for "sound mode takes the smallest stream" (owner
/// ruling 2026-11-17), no network.
///
/// Fixtures are shaped after the playlists the sound-mode bandwidth study
/// actually measured, so a regression here is a regression against a real
/// channel. The two that carry the ruling's whole argument:
///
/// - **A separate audio rendition costs nothing** and is always preferred.
/// - **`BANDWIDTH` order is not audio order** — Deejay TV runs 128/128/64/64
///   with a 256 listed last — so the lowest-`BANDWIDTH` pick is a deliberate
///   quality trade, not an optimisation. It must be picked by value, never by
///   position in the file.
void main() {
  group('pickSoundModeUri — audio renditions', () {
    test('prefers a separate audio rendition over every variant', () {
      expect(pickSoundModeUri(_masterWithRendition), 'audio_it.m3u8');
    });

    test('prefers DEFAULT=YES among several renditions', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",URI="a_eng.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Italiano",DEFAULT=YES,URI="a_ita.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="a"\n'
          'v_360.m3u8\n';
      expect(pickSoundModeUri(playlist), 'a_ita.m3u8');
    });

    test('falls back to the first rendition when none is DEFAULT', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="One",URI="a_one.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Two",URI="a_two.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
          'v_360.m3u8\n';
      expect(pickSoundModeUri(playlist), 'a_one.m3u8');
    });

    test('ignores a TYPE=AUDIO rendition that carries no URI', () {
      // A muxed audio group only *references* the audio inside the variants —
      // there is no separate playlist to open, so the variant pick must win.
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Italiano",DEFAULT=YES\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720,AUDIO="a"\n'
          'v_720.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="a"\n'
          'v_360.m3u8\n';
      expect(pickSoundModeUri(playlist), 'v_360.m3u8');
    });

    test('ignores TYPE=SUBTITLES and TYPE=VIDEO renditions', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="it",URI="sub_it.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="v",NAME="main",URI="vid.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
          'v_720.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
          'v_360.m3u8\n';
      expect(pickSoundModeUri(playlist), 'v_360.m3u8');
    });

    test('TYPE and DEFAULT are matched case-insensitively', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:type=audio,GROUP-ID="a",NAME="it",default=yes,URI="a_it.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
          'v_360.m3u8\n';
      expect(pickSoundModeUri(playlist), 'a_it.m3u8');
    });
  });

  group('pickSoundModeUri — muxed variants', () {
    test('picks the lowest BANDWIDTH, not the first listed', () {
      // The Deejay TV shape: the cheapest variant sits in the middle of the
      // file. Picking by position would take the 3.3 Mbps one.
      expect(pickSoundModeUri(_muxedMultiVariant), 'v_360.m3u8');
    });

    test('keeps a relative URI exactly as written', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          '../chunks/720/index.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          '../chunks/360/index.m3u8\n';
      // Relative, with no leading slash and a parent segment — joining it
      // against the master is the caller's job, not the parser's.
      expect(pickSoundModeUri(playlist), '../chunks/360/index.m3u8');
    });

    test('keeps an absolute URI exactly as written', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          'https://cdn.example.com/hi/index.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'https://cdn.example.com/lo/index.m3u8\n';
      expect(pickSoundModeUri(playlist), 'https://cdn.example.com/lo/index.m3u8');
    });

    test('keeps a query string on the picked URI', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          'hi.m3u8?token=abc&t=1\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'lo.m3u8?token=abc&t=2\n';
      expect(pickSoundModeUri(playlist), 'lo.m3u8?token=abc&t=2');
    });

    test('a quoted CODECS comma does not break the attribute split', () {
      // CODECS="mp4a.40.2,avc1.640028" must not be read as two attributes,
      // or BANDWIDTH on the same line is lost and the variant drops out.
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:CODECS="mp4a.40.2,avc1.640028",BANDWIDTH=3300000,RESOLUTION=1280x720\n'
          'hi.m3u8\n'
          '#EXT-X-STREAM-INF:CODECS="mp4a.40.2,avc1.4d401f",BANDWIDTH=800000,RESOLUTION=640x360\n'
          'lo.m3u8\n';
      expect(pickSoundModeUri(playlist), 'lo.m3u8');
    });

    test('tolerates CRLF line endings', () {
      final playlist = _muxedMultiVariant.replaceAll('\n', '\r\n');
      expect(pickSoundModeUri(playlist), 'v_360.m3u8');
    });

    test('skips tags between a variant and its URI', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          '#EXT-X-SOMETHING-ELSE:ignored\n'
          'hi.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          '\n'
          'lo.m3u8\n';
      expect(pickSoundModeUri(playlist), 'lo.m3u8');
    });
  });

  group('pickSoundModeUri — nothing worth pinning', () {
    test('a media playlist has no variants to choose between', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:8\n'
          '#EXTINF:8.0,\n'
          'segment1.ts\n'
          '#EXTINF:8.0,\n'
          'segment2.ts\n';
      expect(pickSoundModeUri(playlist), isNull);
    });

    test('a single-variant master keeps todays behaviour', () {
      // 35% of the owner's own channels. There is nothing to select, so the
      // master is still what gets opened — no new failure surface for them.
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'only.m3u8\n';
      expect(pickSoundModeUri(playlist), isNull);
    });

    test('no BANDWIDTH on any variant means no comparable pick', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          'hi.m3u8\n'
          '#EXT-X-STREAM-INF:RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'lo.m3u8\n';
      expect(pickSoundModeUri(playlist), isNull);
    });

    test('only one variant carrying BANDWIDTH is not a comparison', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          'hi.m3u8\n'
          '#EXT-X-STREAM-INF:RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'lo.m3u8\n';
      expect(pickSoundModeUri(playlist), isNull);
    });

    test('a variant whose URI line is missing is not pinnable', () {
      // The probe reads a capped 64 KB and drops the trailing partial line,
      // so a master's last variant can genuinely arrive without its URI.
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3300000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"\n'
          'hi.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401f,mp4a.40.2"\n';
      expect(pickSoundModeUri(playlist), isNull);
    });

    test('empty text is null, not a crash', () {
      expect(pickSoundModeUri(''), isNull);
    });
  });

  group('classifyHlsPlaylist is untouched by the URI capture', () {
    test('a master with a rendition is still strong video', () {
      final verdict = classifyHlsPlaylist(_masterWithRendition);
      expect(verdict.kind, StreamKind.video);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.source, KindSource.hlsMasterCodecs);
    });

    test('a muxed multi-variant master is still strong video', () {
      final verdict = classifyHlsPlaylist(_muxedMultiVariant);
      expect(verdict.kind, StreamKind.video);
      expect(verdict.confidence, KindConfidence.strong);
    });

    test('a truncated last variant still counts toward the verdict', () {
      // The regression this guards: moving variant creation onto the URI line
      // would drop the truncated variant and could flip a verdict to unknown.
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=120000,CODECS="mp4a.40.2"\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.strong);
      expect(verdict.locksAudio, isTrue);
    });

    test('an all-audio master over the plausibility ceiling stays provisional',
        () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3500000,CODECS="mp4a.40.2"\n'
          'a.m3u8\n';
      final verdict = classifyHlsPlaylist(playlist);
      expect(verdict.kind, StreamKind.audioOnly);
      expect(verdict.confidence, KindConfidence.provisional);
      expect(verdict.locksAudio, isFalse);
    });
  });
}

/// Rai 3's shape: a `DEFAULT=YES` audio rendition beside two muxed video
/// variants. Pinning the rendition is the zero-quality-cost case — 10% of the
/// owner's own channels.
const String _masterWithRendition = '#EXTM3U\n'
    '#EXT-X-VERSION:4\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="Italiano",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="it",URI="audio_it.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="aud1"\n'
    'video_low.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720,AUDIO="aud1"\n'
    'video_high.m3u8\n';

/// The muxed multi-variant shape — 42% of the owner's channels, and the class
/// the quality trade applies to. The cheapest variant is deliberately listed
/// second so a position-based pick fails this fixture.
const String _muxedMultiVariant = '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=3300000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720\n'
    'v_720.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360\n'
    'v_360.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=1600000,CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=854x480\n'
    'v_480.m3u8\n';
