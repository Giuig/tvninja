import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';

/// Covers the one piece of `removePlaylist` that deletes user data.
///
/// Both `removePlaylist` implementations used to prune favourites with
/// `removeWhere((fid) => fid.startsWith('<playlistId>_'))`. That predicate could
/// never match: `uniqueId` is `url.hashCode`, a bare digit string, while the
/// `<playlistId>_` prefix belongs to the Hive box keys. It looked like cleanup
/// and did nothing, so ids accumulated forever and re-adding a playlist silently
/// resurrected old favourites.
///
/// These tests pin both halves of the replacement: orphans really are pruned,
/// and a favourite still reachable through another playlist is **not**, because
/// identity is deliberately URL-scoped — a favourite follows the stream, not the
/// playlist entry.
void main() {
  Channel channel(String name, String url) => Channel(name: name, url: url);

  Playlist playlist(String id, List<Channel> channels) =>
      Playlist(id: id, name: id, url: 'http://example.test/$id.m3u',
          channels: channels);

  /// Builds a notifier from seeded prefs and waits for its async load.
  ///
  /// Seeding `playlists` matters beyond convenience: `_loadData` fetches a debug
  /// seed playlist over the network when the list is empty, which in a test
  /// would mean a blocked HTTP call and a nondeterministic starting state.
  /// A non-empty list skips that branch entirely.
  Future<AppStatsNotifier> loadedWith({
    required List<Playlist> playlists,
    required Set<String> favourites,
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

  test('a favourite id is a bare number, so the old prefix predicate was dead',
      () {
    // This is why the previous cleanup silently did nothing. Pinned so nobody
    // reintroduces a prefix-based prune.
    final id = channel('Rai 1', 'http://a.test/rai1').uniqueId;
    expect(int.tryParse(id), isNotNull,
        reason: 'uniqueId must stay a plain number for this reasoning to hold');
    expect(id.startsWith('p1_'), isFalse);
  });

  test('removing a playlist prunes favourites that no channel matches any more',
      () async {
    final keep = channel('Keep', 'http://a.test/keep');
    final drop = channel('Drop', 'http://a.test/drop');

    final notifier = await loadedWith(
      playlists: [
        playlist('p1', [keep]),
        playlist('p2', [drop]),
      ],
      favourites: {keep.uniqueId, drop.uniqueId},
    );
    expect(notifier.favoriteChannelIds, hasLength(2));

    await notifier.removePlaylist('p2');

    expect(notifier.favoriteChannelIds, contains(keep.uniqueId));
    expect(notifier.favoriteChannelIds, isNot(contains(drop.uniqueId)),
        reason: 'the removed playlist was the only source of that channel');
    expect(notifier.favoriteChannelIds, hasLength(1));
  });

  test('a favourite still reachable through another playlist survives',
      () async {
    // The deliberate half: identity is URL-scoped, so the same stream present in
    // two playlists is one favourite and removing one playlist must not drop it.
    const sharedUrl = 'http://a.test/shared';
    final inP1 = channel('Shared', sharedUrl);
    final inP2 = channel('Shared, other playlist', sharedUrl);
    expect(inP1.uniqueId, inP2.uniqueId,
        reason: 'same url means same identity, by design');

    final notifier = await loadedWith(
      playlists: [
        playlist('p1', [inP1]),
        playlist('p2', [inP2]),
      ],
      favourites: {inP1.uniqueId},
    );

    await notifier.removePlaylist('p2');

    expect(notifier.favoriteChannelIds, contains(inP1.uniqueId),
        reason: 'the channel still exists in p1, so the favourite stands');
  });

  test('removing the last playlist clears every favourite', () async {
    final only = channel('Only', 'http://a.test/only');

    final notifier = await loadedWith(
      playlists: [
        playlist('p1', [only])
      ],
      favourites: {only.uniqueId},
    );

    await notifier.removePlaylist('p1');

    expect(notifier.favoriteChannelIds, isEmpty,
        reason: 'no channels left, so no favourite can still be valid');
  });

  test('an unrelated empty playlist does not drag favourites down with it',
      () async {
    // A playlist can legitimately hold no channels — a failed refresh leaves the
    // old one intact, but a freshly added one can be empty. Removing it must not
    // disturb anything else.
    final keep = channel('Keep', 'http://a.test/keep');

    final notifier = await loadedWith(
      playlists: [
        playlist('p1', [keep]),
        playlist('empty', const []),
      ],
      favourites: {keep.uniqueId},
    );

    await notifier.removePlaylist('empty');

    expect(notifier.favoriteChannelIds, contains(keep.uniqueId));
  });
}
