import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';

/// Covers the two dedupe fixes reported by the owner 2026-09-22:
/// the same playlist could be added repeatedly, and a stream present in two
/// playlists appeared twice in the favourites grid.
void main() {
  Channel channel(String name, String url) => Channel(name: name, url: url);

  Playlist playlist(String id, String url, List<Channel> channels) =>
      Playlist(id: id, name: id, url: url, channels: channels);

  /// Builds a notifier from seeded prefs and waits for its async load.
  ///
  /// Seeding `playlists` also keeps the debug seed out of the way: `_loadData`
  /// only seeds when the list is empty.
  Future<AppStatsNotifier> loadedWith({
    required List<Playlist> playlists,
    Set<String> favourites = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'playlists': playlists.map((p) => jsonEncode(p.toJson())).toList(),
      'favorites': favourites.toList(),
    });
    final notifier = AppStatsNotifier();
    while (notifier.isLoading) {
      await Future<void>.delayed(Duration.zero);
    }
    return notifier;
  }

  group('playlist dedupe', () {
    test('the same url is rejected', () async {
      final notifier = await loadedWith(
        playlists: [
          playlist('p1', 'http://a.test/list.m3u', [channel('A', 'http://s/1')])
        ],
      );

      final added = await notifier.addPlaylist(
        playlist('p2', 'http://a.test/list.m3u', const []),
      );

      expect(added, isFalse);
      expect(notifier.playlists, hasLength(1));
    });

    test('a trailing slash or different case is still the same url', () async {
      final notifier = await loadedWith(
        playlists: [playlist('p1', 'http://a.test/List.m3u', const [])],
      );

      expect(
        await notifier.addPlaylist(
            playlist('p2', 'http://A.TEST/list.m3u/', const [])),
        isFalse,
      );
      expect(notifier.playlists, hasLength(1));
    });

    test('a genuinely different url is added', () async {
      final notifier = await loadedWith(
        playlists: [playlist('p1', 'http://a.test/list.m3u', const [])],
      );

      expect(
        await notifier
            .addPlaylist(playlist('p2', 'http://a.test/other.m3u', const [])),
        isTrue,
      );
      expect(notifier.playlists, hasLength(2));
    });

    test('the query string is part of the identity', () async {
      // Xtream playlists carry the username and password there, so two entries
      // differing only in query are different playlists — not duplicates.
      final notifier = await loadedWith(
        playlists: [
          playlist('p1', 'http://a.test/get.php?username=u1&password=p', const [])
        ],
      );

      expect(
        await notifier.addPlaylist(playlist(
            'p2', 'http://a.test/get.php?username=u2&password=p', const [])),
        isTrue,
      );
      expect(notifier.playlists, hasLength(2));
    });

    test('an empty url is never a duplicate', () async {
      // The debug seed has one, and so would any playlist not fetched from
      // anywhere. Two of them must not collide.
      final notifier = await loadedWith(
        playlists: [playlist('p1', '', const [])],
      );

      expect(await notifier.addPlaylist(playlist('p2', '', const [])), isTrue);
      expect(notifier.playlists, hasLength(2));
    });
  });

  group('favourites dedupe', () {
    test('a stream in two playlists yields one favourite entry', () async {
      // Deliberately two DIFFERENT playlists that happen to share a stream —
      // adding the same playlist twice is no longer possible, so reproducing
      // this the old way would silently test nothing.
      const shared = 'http://s.test/shared';
      final inP1 = channel('Shared', shared);
      final inP2 = channel('Shared, other list', shared);
      expect(inP1.uniqueId, inP2.uniqueId, reason: 'same url, same identity');

      final notifier = await loadedWith(
        playlists: [
          playlist('p1', 'http://a.test/one.m3u', [inP1]),
          playlist('p2', 'http://a.test/two.m3u', [inP2]),
        ],
        favourites: {inP1.uniqueId},
      );

      expect(notifier.favoriteChannels, hasLength(1));
      expect(notifier.favoriteChannels.single.name, 'Shared',
          reason: 'first occurrence wins, so the order is predictable');
    });

    test('distinct favourited streams are all still listed', () async {
      final a = channel('A', 'http://s.test/a');
      final b = channel('B', 'http://s.test/b');

      final notifier = await loadedWith(
        playlists: [
          playlist('p1', 'http://a.test/one.m3u', [a, b])
        ],
        favourites: {a.uniqueId, b.uniqueId},
      );

      expect(notifier.favoriteChannels, hasLength(2));
    });
  });
}
