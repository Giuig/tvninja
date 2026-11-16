// Carrying the M3U `radio="true"` attribute through `M3UChannel` -> `Channel`
// -> json -> `copyWith`. The shared metadata regex only keeps the quoted form
// (`group(2)`), so `radio` is read separately via `group(2) ?? group(3)` to
// also catch the unquoted form. `copyWith` rebuilds field by field, and
// `_buildAllChannelsList` runs every channel through it — a field it misses is
// dropped app-wide.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/services/m3u_parser.dart';

void main() {
  group('M3UParser: radio attribute', () {
    test('quoted radio="true" is read as isRadio: true', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-name="BBC Radio 3" radio="true",BBC Radio 3\n'
          'https://example.com/bbc-r3.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'test-playlist');

      expect(channels, hasLength(1));
      expect(channels.single.isRadio, isTrue);
    });

    test('unquoted radio=true is read as isRadio: true', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-name="BBC Radio 3" radio=true,BBC Radio 3\n'
          'https://example.com/bbc-r3.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'test-playlist');

      expect(channels, hasLength(1));
      expect(channels.single.isRadio, isTrue);
    });

    test('radio="true" comparison is case-insensitive', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-name="BBC Radio 3" radio="True",BBC Radio 3\n'
          'https://example.com/bbc-r3.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'test-playlist');

      expect(channels, hasLength(1));
      expect(channels.single.isRadio, isTrue);
    });

    test('a channel with no radio attribute is isRadio: false', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-name="LA7",LA7\n'
          'https://example.com/la7.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'test-playlist');

      expect(channels, hasLength(1));
      expect(channels.single.isRadio, isFalse);
    });

    test('radio="false" is isRadio: false, not just "present therefore true"',
        () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-name="LA7" radio="false",LA7\n'
          'https://example.com/la7.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'test-playlist');

      expect(channels, hasLength(1));
      expect(channels.single.isRadio, isFalse);
    });

    test('the generic metadata loop is unchanged: tvg-name still parses '
        'alongside an unquoted radio attribute', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="r3.bbc" tvg-name="BBC Radio 3" '
          'tvg-logo="logo.png" group-title="Radio" radio=true,BBC Radio 3\n'
          'https://example.com/bbc-r3.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'test-playlist');

      expect(channels, hasLength(1));
      final c = channels.single;
      expect(c.name, 'BBC Radio 3');
      expect(c.logo, 'logo.png');
      expect(c.group, 'Radio');
      expect(c.isRadio, isTrue);
    });

    test('M3UChannel.toChannel carries isRadio through', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-name="BBC Radio 3" radio="true",BBC Radio 3\n'
          'https://example.com/bbc-r3.m3u8\n';

      final channels = M3UParser.parseSync(m3u, 'my-playlist');

      expect(channels, hasLength(1));
      final channel = channels.single;
      expect(channel, isA<Channel>());
      expect(channel.isRadio, isTrue);
      expect(channel.playlistId, 'my-playlist');
    });
  });

  group('Channel.isRadio: json and copyWith', () {
    test('toJson/fromJson round-trips isRadio: true', () {
      final channel = Channel(
        name: 'BBC Radio 3',
        url: 'https://example.com/bbc-r3.m3u8',
        isRadio: true,
      );

      final decoded = Channel.fromJson(jsonDecode(jsonEncode(channel.toJson())));

      expect(decoded.isRadio, isTrue);
    });

    test('toJson/fromJson round-trips isRadio: false', () {
      final channel = Channel(
        name: 'LA7',
        url: 'https://example.com/la7.m3u8',
        isRadio: false,
      );

      final decoded = Channel.fromJson(jsonDecode(jsonEncode(channel.toJson())));

      expect(decoded.isRadio, isFalse);
    });

    test('a legacy json blob with no isRadio key loads as false', () {
      final legacyJson = {
        'name': 'LA7',
        'url': 'https://example.com/la7.m3u8',
        'logo': null,
        'group': null,
        'playlistId': 'p1',
        'type': 'live',
        'userAgent': null,
        // no 'isRadio' key at all — this is what every channel stored
        // before this field existed looks like on disk.
      };

      final channel = Channel.fromJson(legacyJson);

      expect(channel.isRadio, isFalse);
    });

    test('copyWith(playlistId:) preserves isRadio', () {
      final channel = Channel(
        name: 'BBC Radio 3',
        url: 'https://example.com/bbc-r3.m3u8',
        isRadio: true,
      );

      final copy = channel.copyWith(playlistId: 'new-playlist-id');

      expect(copy.isRadio, isTrue);
      expect(copy.playlistId, 'new-playlist-id');
    });

    test('copyWith(playlistId:) preserves isRadio: false too', () {
      final channel = Channel(
        name: 'LA7',
        url: 'https://example.com/la7.m3u8',
        isRadio: false,
      );

      final copy = channel.copyWith(playlistId: 'new-playlist-id');

      expect(copy.isRadio, isFalse);
    });

    test('copyWith(isRadio:) can override it explicitly', () {
      final channel = Channel(
        name: 'BBC Radio 3',
        url: 'https://example.com/bbc-r3.m3u8',
        isRadio: true,
      );

      final copy = channel.copyWith(isRadio: false);

      expect(copy.isRadio, isFalse);
    });
  });
}
