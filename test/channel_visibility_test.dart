import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/services/channel_visibility.dart';

Channel _ch(String name, String url) => Channel(name: name, url: url);

void main() {
  group('isPlainHttp', () {
    test('plain http is plain http', () {
      expect(isPlainHttp('http://cdns.example.com:8000/live.m3u8'), isTrue);
    });

    test('https is NOT, despite sharing the prefix', () {
      // The obvious off-by-one: a naive startsWith('http') would call this
      // plain http and hide every working channel on web.
      expect(isPlainHttp('https://example.com/live.m3u8'), isFalse);
    });

    test('an uppercase scheme still counts', () {
      // Playlists are third-party text; HTTP:// does occur in the wild, and
      // missing it would readmit exactly what this module exists to hide.
      expect(isPlainHttp('HTTP://example.com/a.m3u8'), isTrue);
      expect(isPlainHttp('Http://example.com/a.m3u8'), isTrue);
    });

    test('leading whitespace does not hide the scheme', () {
      expect(isPlainHttp('  http://example.com/a.m3u8'), isTrue);
    });

    test('a non-http scheme is not plain http', () {
      expect(isPlainHttp('rtsp://example.com/a'), isFalse);
      expect(isPlainHttp(''), isFalse);
    });
  });

  group('upgradeToHttps', () {
    test('upgrades a plain http url', () {
      expect(upgradeToHttps('http://a.example:8000/x.m3u8'),
          'https://a.example:8000/x.m3u8');
    });

    test('upgrades an UPPERCASE scheme instead of silently returning it', () {
      // The bug this function exists to prevent: replaceFirst('http://', …) is
      // case-sensitive, so this used to come back unchanged and get added as
      // the "upgraded" candidate — retrying the identical failing URL.
      final out = upgradeToHttps('HTTP://a.example/x.m3u8');
      expect(out, 'https://a.example/x.m3u8');
      expect(isPlainHttp(out), isFalse, reason: 'must not still be plain http');
    });

    test('drops leading whitespace, like isPlainHttp does', () {
      expect(upgradeToHttps('  http://a.example/x'), 'https://a.example/x');
    });

    test('anything isPlainHttp accepts upgrades to the exact https url', () {
      // The pairing is the contract: the caller gates on isPlainHttp and then
      // calls this, so a disagreement between them would be a silent no-op.
      // Asserted as exact equality — `startsWith('https://')` would also pass
      // for 'https://http://a/b', i.e. for never stripping the old scheme.
      for (final u in [
        'http://a/b',
        'HTTP://a/b',
        'Http://a/b',
        '  http://a/b',
      ]) {
        expect(isPlainHttp(u), isTrue, reason: u);
        expect(upgradeToHttps(u), 'https://a/b', reason: u);
      }
    });

    test('preserves query and fragment untouched', () {
      expect(upgradeToHttps('http://a/b?token=x&y=1#z'),
          'https://a/b?token=x&y=1#z');
    });
  });

  group('blocksPlainHttp', () {
    test('web on an https page blocks', () {
      expect(
        blocksPlainHttp(isWeb: true, pageUri: Uri.parse('https://giuig.github.io/tvninja/')),
        isTrue,
      );
    });

    test('web on an http page does NOT block', () {
      // The development case. Keying this on kIsWeb alone would hide ~101 JP
      // channels in `flutter run -d chrome` and make the live bug impossible
      // to reproduce locally.
      expect(
        blocksPlainHttp(isWeb: true, pageUri: Uri.parse('http://localhost:8080/')),
        isFalse,
      );
    });

    test('native never blocks, whatever the uri looks like', () {
      expect(
        blocksPlainHttp(isWeb: false, pageUri: Uri.parse('https://example.com/')),
        isFalse,
      );
      expect(
        blocksPlainHttp(isWeb: false, pageUri: Uri.parse('file:///C:/app/')),
        isFalse,
      );
    });
  });

  group('visibleChannels', () {
    final mixed = [
      _ch('https one', 'https://a.example/1.m3u8'),
      _ch('http one', 'http://b.example:8000/2.m3u8'),
      _ch('https two', 'https://c.example/3.m3u8'),
      _ch('http two', 'HTTP://d.example/4.m3u8'),
    ];

    test('keeps everything when not blocking', () {
      final out = visibleChannels(mixed, blockPlainHttp: false);
      expect(out, hasLength(4));
      expect(out, same(mixed), reason: 'no copy needed on the native path');
    });

    test('drops only the plain-http ones when blocking', () {
      final out = visibleChannels(mixed, blockPlainHttp: true);
      expect(out.map((c) => c.name), ['https one', 'https two']);
    });

    test('preserves order', () {
      final out = visibleChannels([
        _ch('a', 'https://a.example/a'),
        _ch('skip', 'http://b.example/b'),
        _ch('b', 'https://c.example/c'),
        _ch('c', 'https://d.example/d'),
      ], blockPlainHttp: true);
      expect(out.map((c) => c.name), ['a', 'b', 'c']);
    });

    test('an all-http playlist becomes empty rather than partly broken', () {
      // The caller relies on this: an empty result with a non-empty source is
      // what makes the list fall through to "no channels match" instead of
      // showing rows that cannot play.
      final out = visibleChannels([
        _ch('x', 'http://a.example/x'),
        _ch('y', 'http://b.example/y'),
      ], blockPlainHttp: true);
      expect(out, isEmpty);
    });

    test('an empty list stays empty on both paths', () {
      expect(visibleChannels([], blockPlainHttp: true), isEmpty);
      expect(visibleChannels([], blockPlainHttp: false), isEmpty);
    });
  });
}
