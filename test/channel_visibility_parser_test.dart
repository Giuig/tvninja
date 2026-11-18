import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/channel_visibility.dart';
import 'package:tvninja/services/m3u_parser.dart';

/// Parser → filter, together.
///
/// `channel_visibility_test.dart` tests the filter on hand-built [Channel]s.
/// That cannot catch a disagreement between the two layers — if the parser ever
/// normalised, trimmed or re-cased a URL on its way into `Channel.url`, the
/// filter could silently stop matching and every hidden channel would come
/// back. This pins the whole path on a playlist shaped like the real ones:
/// attributes, groups, a mixed-case scheme and an indented URL line.
///
/// Verified against the real data on 2026-11-18 (one-off run, not committed —
/// the playlists are private): the JP playlist parsed 219 and showed 118 on
/// an https page, the IT one parsed 725 and showed 674, with native hiding
/// nothing.
const _playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="a.jp" tvg-logo="https://logo/a.png" group-title="News",Alpha HTTPS
https://cdn.example/alpha/index.m3u8
#EXTINF:-1 tvg-id="b.jp" group-title="News",Bravo HTTP
http://cdns.example:8000/bravo.m3u8?cid=gx06&uin=1
#EXTINF:-1 tvg-id="c.jp" group-title="Anime",Charlie UPPERCASE
HTTP://cdns.example:8000/charlie.m3u8
#EXTINF:-1 tvg-id="d.jp" group-title="Anime",Delta HTTPS
https://cdn.example/delta/index.m3u8
#EXTINF:-1 group-title="Other",Echo indented http
   http://cdns.example:8000/echo.m3u8
#EXTINF:-1 group-title="Other",Foxtrot https lookalike
https://httpsonly.example/http://not-really.m3u8
''';

void main() {
  test('the parser and the filter agree on what plain http is', () {
    final channels = M3UParser.parseSync(_playlist, 'test');
    expect(channels, hasLength(6), reason: 'fixture should parse completely');

    final onHttpsPage = visibleChannels(channels, blockPlainHttp: true);

    expect(
      onHttpsPage.map((c) => c.name),
      ['Alpha HTTPS', 'Delta HTTPS', 'Foxtrot https lookalike'],
      reason: 'the three https channels survive; the lowercase, uppercase and '
          'indented http ones do not',
    );
  });

  test('native keeps every parsed channel, including the http ones', () {
    final channels = M3UParser.parseSync(_playlist, 'test');
    expect(visibleChannels(channels, blockPlainHttp: false), hasLength(6));
  });

  test('a url containing "http://" in its PATH is not treated as plain http',
      () {
    // Foxtrot is served over https but has "http://" inside the path. A filter
    // written with `contains` instead of a scheme check would wrongly hide it.
    final channels = M3UParser.parseSync(_playlist, 'test');
    final foxtrot = channels.firstWhere((c) => c.name.startsWith('Foxtrot'));
    expect(isPlainHttp(foxtrot.url), isFalse);
    expect(visibleChannels([foxtrot], blockPlainHttp: true), hasLength(1));
  });

  test('the hidden channels upgrade to the exact https url, scheme and all',
      () {
    // Exact equality, deliberately. `startsWith('https://')` is satisfied by
    // 'https://' + anything — including 'https://http://cdns…' if the old
    // scheme were never stripped, or a tail with a character dropped. That
    // assertion cannot tell a correct implementation from a broken one, so it
    // is not a test. These are the URLs the web player will actually request.
    final channels = M3UParser.parseSync(_playlist, 'test');
    final byName = {for (final c in channels) c.name: c.url};

    expect(upgradeToHttps(byName['Bravo HTTP']!),
        'https://cdns.example:8000/bravo.m3u8?cid=gx06&uin=1');
    expect(upgradeToHttps(byName['Charlie UPPERCASE']!),
        'https://cdns.example:8000/charlie.m3u8');
    expect(upgradeToHttps(byName['Echo indented http']!),
        'https://cdns.example:8000/echo.m3u8');
  });
}
