// Focused regression test for the EXTVLCOPT user-agent chain (Bug 2 root
// cause, found via live testing on the ExoEngine path: RAI channels 403
// specifically on ExoPlayer, where mpv's own default UA ("mpv") happened to
// already satisfy RAI's relinker, silently masking whether this chain ever
// actually worked). Verifies `M3UParser` alone — the one link in the chain
// that can be checked without a device or a Flutter widget harness.
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/m3u_parser.dart';

void main() {
  test('a well-formed #EXTVLCOPT:http-user-agent line is captured for its channel', () {
    const m3u = '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="rai3.it" tvg-name="Rai 3" tvg-logo="logo.png" group-title="RAI",Rai 3\n'
        '#EXTVLCOPT:http-user-agent=HbbTV/1.6.1\n'
        'https://mediapolis.rai.it/relinker/relinkerServlet.htm?cont=example\n';

    final channels = M3UParser.parseSync(m3u, 'test-playlist');

    expect(channels, hasLength(1));
    expect(channels.single.name, 'Rai 3');
    expect(channels.single.userAgent, 'HbbTV/1.6.1');
  });

  test('a channel with no EXTVLCOPT line has a null userAgent, not a stale one', () {
    const m3u = '#EXTM3U\n'
        '#EXTINF:-1 tvg-name="LA7",LA7\n'
        'https://example.com/la7.m3u8\n';

    final channels = M3UParser.parseSync(m3u, 'test-playlist');

    expect(channels, hasLength(1));
    expect(channels.single.userAgent, isNull);
  });

  test(
      'REGRESSION: a channel with no EXTVLCOPT line does NOT inherit a prior '
      'channel\'s user-agent, even when the prior channel entry is malformed '
      'and skipped. Before the fix in _parseLinesSync (the `continue` for a '
      'skipped block now resets `infoMatch`/`kodiMatches`/`userAgent` just '
      'like the successful-add path does), this test failed with '
      "'SomeOtherUA/1.0' leaking onto the next, unrelated channel.", () {
    const m3u = '#EXTM3U\n'
        // Malformed EXTINF (no comma/title — _infoRegex requires one), so
        // this whole block is skipped via the `infoMatch == null` continue —
        // which, pre-fix, left the shared `userAgent` variable un-reset.
        '#EXTVLCOPT:http-user-agent=SomeOtherUA/1.0\n'
        '#EXTINF:-1 tvg-name="broken"\n'
        'https://example.com/broken.m3u8\n'
        // A well-formed channel with no EXTVLCOPT of its own immediately
        // after the skipped block.
        '#EXTINF:-1 tvg-name="Rai 3",Rai 3\n'
        'https://mediapolis.rai.it/relinker/relinkerServlet.htm?cont=example\n';

    final channels = M3UParser.parseSync(m3u, 'test-playlist');

    expect(channels, hasLength(1));
    expect(channels.single.name, 'Rai 3');
    expect(channels.single.userAgent, isNull);
  });
}
