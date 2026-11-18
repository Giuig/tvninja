import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The pages read their state through `provider`, which the app uses but does
// not list as a direct dependency (pre-existing; same info on `lib`).
// ignore: depend_on_referenced_packages
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/channel_list_page.dart';
import 'package:tvninja/pages/home_page.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/channel_visibility.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';

import 'support/platform_channel_mocks.dart';

/// The https branch, through the widgets that actually ship.
///
/// ## Why a widget test and not a browser
///
/// `channel_visibility_test.dart` proves the pure functions and
/// `channel_visibility_parser_test.dart` proves the parser agrees with them,
/// but neither executes the *wiring*: the pages reading
/// `platformBlocksPlainHttp()`, the group chips and the `nChannels` count
/// being computed from the filtered list, and — the part that actually broke
/// in review — the filtered list reaching `PlayerPage`.
///
/// That branch is unreachable off the web: in a test `kIsWeb` is false and
/// `Uri.base` is a `file:` URI, so the pages would always take the native
/// path. `debugBlockPlainHttpOverride` is the seam that makes the https path
/// renderable here; what remains unproven by this file is only whether
/// `Uri.base` reports https on a real https page, which is a Dart platform
/// guarantee.
///
/// Verified against the real playlists on 2026-11-18 by running the real
/// parser and filter over them once (not committed — they are private):
/// the JP playlist's 219 entries showed 118, the IT one's 725 showed 674.
///
/// ## The fixture
///
/// Ordered so that a wrong index cannot pass. `Charlie` is the second
/// *visible* channel but the third overall, so handing the player an
/// unfiltered list, or an index computed against one, opens the wrong
/// channel. `Sports` exists only as an http channel, so its group chip must
/// disappear with it; `Delta` is uppercase-scheme, which a case-sensitive
/// check would miss.
List<Channel> get _fixture => [
      Channel(name: 'Alpha', url: 'https://cdn.example/alpha.m3u8', group: 'News'),
      Channel(
          name: 'Bravo', url: 'http://cdns.example:8000/bravo.m3u8', group: 'News'),
      Channel(
          name: 'Charlie', url: 'https://cdn.example/charlie.m3u8', group: 'Anime'),
      Channel(
          name: 'Delta', url: 'HTTP://cdns.example:8000/delta.m3u8', group: 'Anime'),
      Channel(name: 'Echo', url: 'https://cdn.example/echo.m3u8', group: 'Anime'),
      Channel(
          name: 'Foxtrot',
          url: 'http://cdns.example:8000/foxtrot.m3u8',
          group: 'Sports'),
    ];

const _playlistId = 'fixture-playlist';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
    mockPlayerPlatformChannels();
  });

  tearDown(() {
    // Global state: left set, it would silently hide http channels in every
    // later test in this process.
    debugBlockPlainHttpOverride = null;
    clearPlayerPlatformChannelMocks();
  });

  /// A notifier holding the fixture playlist, plus any [favorites] by name.
  ///
  /// Seeded through `SharedPreferences` rather than `addPlaylist`, because the
  /// notifier's constructor starts a `_loadData()` that *reassigns*
  /// `_playlists` from prefs when it lands — so a playlist added before then is
  /// silently wiped, which is exactly what the first run of this file hit. Also
  /// keeps the debug seed playlist out of the way (it is only added when the
  /// loaded list is empty) and exercises the real load path on the way in.
  AppStatsNotifier seeded({List<String> favorites = const []}) {
    final channels = _fixture;
    final playlist = Playlist(
      id: _playlistId,
      name: 'Fixture',
      url: 'https://example.invalid/fixture.m3u',
      channels: channels,
    );
    SharedPreferences.setMockInitialValues({
      'playlists': [jsonEncode(playlist.toJson())],
      'favorites': [
        for (final name in favorites)
          channels.firstWhere((c) => c.name == name).uniqueId,
      ],
    });
    return AppStatsNotifier();
  }

  Future<void> mount(
      WidgetTester tester, AppStatsNotifier stats, Widget page) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: stats,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ));
    // `_loadData()` resolves against the mock prefs on the microtask queue,
    // which each pump drains. Pumped unconditionally: ChannelListPage renders
    // an empty box (not a spinner) until the playlist arrives, so there is no
    // single widget to wait on for both pages.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the page never finished loading, so nothing below is tested');
  }

  group('ChannelListPage on an https page', () {
    testWidgets('lists only the channels a browser can load, and counts them',
        (tester) async {
      debugBlockPlainHttpOverride = true;
      await mount(tester, seeded(), const ChannelListPage(playlistId: _playlistId));

      for (final visible in ['Alpha', 'Charlie', 'Echo']) {
        expect(find.text(visible), findsOneWidget, reason: visible);
      }
      for (final hidden in ['Bravo', 'Delta', 'Foxtrot']) {
        expect(find.text(hidden), findsNothing,
            reason: '$hidden is plain http and cannot load on an https page');
      }
      // The count is computed from the same filtered list as the rows, so this
      // failing would mean the header can promise channels the list does not
      // show.
      expect(find.text('3 channels'), findsOneWidget);
    });

    testWidgets('offers no group whose every channel is hidden',
        (tester) async {
      debugBlockPlainHttpOverride = true;
      await mount(tester, seeded(), const ChannelListPage(playlistId: _playlistId));

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();

      Finder item(String label) => find.descendant(
          of: find.byType(PopupMenuItem<String>), matching: find.text(label));

      expect(item('News'), findsOneWidget, reason: 'Alpha survives');
      expect(item('Anime'), findsOneWidget, reason: 'Charlie and Echo survive');
      expect(item('Sports'), findsNothing,
          reason: 'Foxtrot is its only channel and is hidden, so picking the '
              'group could only ever show an empty list');
    });

    testWidgets('hands the player the filtered list, not the playlist',
        (tester) async {
      debugBlockPlainHttpOverride = true;
      await mount(tester, seeded(), const ChannelListPage(playlistId: _playlistId));

      // Charlie is visible #1 but playlist #2. An index taken against the
      // unfiltered list would open Bravo, which cannot play at all.
      await tester.tap(find.text('Charlie'));
      await tester.pump();

      // `skipOffstage: false`: on a push, the incoming route is built
      // offstage for its first frame, so the default finder would miss a
      // page that is demonstrably already mounted.
      final player = tester
          .widget<PlayerPage>(find.byType(PlayerPage, skipOffstage: false));
      expect(player.channel.name, 'Charlie');
      expect(player.channels?.map((c) => c.name).toList(),
          ['Alpha', 'Charlie', 'Echo'],
          reason: 'zapping must not land on a channel the page hid');
      expect(player.initialIndex, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('ChannelListPage natively', () {
    testWidgets('keeps every channel, http included', (tester) async {
      debugBlockPlainHttpOverride = false;
      await mount(tester, seeded(), const ChannelListPage(playlistId: _playlistId));

      for (final name in [
        'Alpha',
        'Bravo',
        'Charlie',
        'Delta',
        'Echo',
        'Foxtrot'
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text('6 channels'), findsOneWidget);
    });

    testWidgets('hands the player the whole playlist', (tester) async {
      debugBlockPlainHttpOverride = false;
      await mount(tester, seeded(), const ChannelListPage(playlistId: _playlistId));

      await tester.tap(find.text('Charlie'));
      await tester.pump();

      // `skipOffstage: false`: on a push, the incoming route is built
      // offstage for its first frame, so the default finder would miss a
      // page that is demonstrably already mounted.
      final player = tester
          .widget<PlayerPage>(find.byType(PlayerPage, skipOffstage: false));
      expect(player.channels, hasLength(6),
          reason: 'Android must be untouched by the web filter');
      expect(player.initialIndex, 2);
    });
  });

  group('HomePage favourites on an https page', () {
    testWidgets('hides the http favourite and agrees with its own count',
        (tester) async {
      debugBlockPlainHttpOverride = true;
      final stats = seeded(favorites: ['Alpha', 'Bravo', 'Charlie']);
      await mount(tester, stats, const HomePage());

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Charlie'), findsOneWidget);
      expect(find.text('Bravo'), findsNothing,
          reason: 'the card itself must go, not just the tap: a rendered card '
              'whose channel is filtered out of the hand-off is what made '
              'indexOf return -1');
      // 2 favourites of 6 channels in 1 playlist, so this number is only the
      // favourites tile.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('hands the player the filtered favourites', (tester) async {
      debugBlockPlainHttpOverride = true;
      final stats = seeded(favorites: ['Alpha', 'Bravo', 'Charlie']);
      await mount(tester, stats, const HomePage());

      await tester.tap(find.text('Alpha'));
      await tester.pump();

      // `skipOffstage: false`: on a push, the incoming route is built
      // offstage for its first frame, so the default finder would miss a
      // page that is demonstrably already mounted.
      final player = tester
          .widget<PlayerPage>(find.byType(PlayerPage, skipOffstage: false));
      expect(player.channel.name, 'Alpha');
      expect(player.channels?.map((c) => c.name).toList(), ['Alpha', 'Charlie']);
      expect(player.initialIndex, 0,
          reason: 'never -1, which PlayerPage would read as a real index');
      expect(tester.takeException(), isNull);
    });
  });
}
