import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/native_audio_service.dart';

/// How a cached sound-mode URI is turned back into something openable.
///
/// The URI is stored relative and unjoined (it outlives any CDN token by up
/// to 30 days), so the join happens on every open against a master resolved
/// on that same call. These cases are what the join has to get right — and
/// one case it deliberately gets "wrong", documented below.
String join(String master, String uri) =>
    NativeAudioService.joinSoundModeUriForTest(master, uri);

void main() {
  group('joining a sound-mode URI against its master', () {
    test('a sibling URI lands next to the master', () {
      expect(
        join('https://cdn.example.com/live/master.m3u8', 'v_360.m3u8'),
        'https://cdn.example.com/live/v_360.m3u8',
      );
    });

    test('a parent-relative URI walks up from the master', () {
      expect(
        join('https://cdn.example.com/live/hd/master.m3u8',
            '../chunks/360/index.m3u8'),
        'https://cdn.example.com/live/chunks/360/index.m3u8',
      );
    });

    test('a root-relative URI lands at the host root', () {
      expect(
        join('https://cdn.example.com/live/master.m3u8', '/abs/v_360.m3u8'),
        'https://cdn.example.com/abs/v_360.m3u8',
      );
    });

    test('an absolute URI is taken as it stands', () {
      // The safest case: nothing about the master's path can make it wrong.
      expect(
        join('https://cdn.example.com/live/master.m3u8',
            'https://other.example.net/lo/index.m3u8'),
        'https://other.example.net/lo/index.m3u8',
      );
    });

    test("a variant's own query string is preserved", () {
      expect(
        join('https://cdn.example.com/live/master.m3u8', 'lo.m3u8?token=abc'),
        'https://cdn.example.com/live/lo.m3u8?token=abc',
      );
    });

    test('an http master joins over http, not https', () {
      expect(
        join('http://cdn.example.com/live/master.m3u8', 'v_360.m3u8'),
        'http://cdn.example.com/live/v_360.m3u8',
      );
    });

    test('a port on the master is kept', () {
      expect(
        join('http://10.0.0.5:8080/live/master.m3u8', 'v_360.m3u8'),
        'http://10.0.0.5:8080/live/v_360.m3u8',
      );
    });

    test('an unparseable master falls back to the master itself', () {
      // Whatever cannot be reasoned about, the app opens what it opened
      // before any pinning existed.
      const broken = 'http://[';
      expect(join(broken, 'v_360.m3u8'), broken);
    });

    test('an unparseable URI reference falls back to the master', () {
      const master = 'https://cdn.example.com/live/master.m3u8';
      expect(join(master, 'http://['), master);
    });
  });

  group('known limitation, pinned here on purpose', () {
    test("a token in the MASTER's query is not carried onto the variant", () {
      // RFC-correct — a relative reference replaces the whole query — and
      // deliberately not worked around: copying a master's query onto a
      // variant URL is wrong in general (a variant that needs a token carries
      // its own, as the fixtures in sound_mode_uri_test show, and a
      // master-scoped token may not be valid for a variant at all).
      //
      // The consequence is real and accepted: on a CDN that tokenises only
      // the master, the pinned variant will 403 on its first open, the
      // reconnect chain sees a pin that never played, and it falls back to
      // the master — one wasted open per session, then today's behaviour.
      // It also means such channels show none of the measured saving, which
      // matters when reading Phase 5's before/after numbers.
      expect(
        join('https://cdn.example.com/live/master.m3u8?token=secret',
            'v_360.m3u8'),
        'https://cdn.example.com/live/v_360.m3u8',
      );
    });
  });
}
