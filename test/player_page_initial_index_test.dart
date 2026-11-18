import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The page reads its stats through `provider`, which the app uses but does not
// list as a direct dependency (pre-existing; see the same info on `lib`).
// ignore: depend_on_referenced_packages
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';

import 'support/platform_channel_mocks.dart';

/// `PlayerPage` must open the channel it was handed, not whatever sits at
/// index 0.
///
/// ## Why these exist
///
/// A caller that filters its channel list — which `home_page.dart` and
/// `channel_list_page.dart` both now do on https web, to drop plain-http
/// streams a browser cannot load — can compute `list.indexOf(channel)` and get
/// **-1** for a channel that was filtered out. `-1` is not null, so it used to
/// survive the `??`, hit the `== -1` branch and silently open `_channels[0]`:
/// the user taps one channel and a different one plays. An empty filtered list
/// was worse — `_channels[0]` threw a RangeError and took the player down.
///
/// Both were found by review before shipping, which is exactly why they are
/// pinned here: the symptom (wrong channel) looks like a zapping bug and would
/// be very hard to trace back to an index.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
    mockPlayerPlatformChannels();
  });

  tearDown(clearPlayerPlatformChannelMocks);

  Channel ch(String name) =>
      Channel(name: name, url: 'http://127.0.0.1:1/$name.m3u8');

  Future<void> open(
    WidgetTester tester, {
    required Channel channel,
    List<Channel>? channels,
    int? initialIndex,
  }) async {
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppStatsNotifier(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerPage(
          channel: channel,
          channels: channels,
          initialIndex: initialIndex,
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('an initialIndex of -1 opens the named channel, not channel 0',
      (tester) async {
    final a = ch('alpha'), b = ch('bravo'), c = ch('charlie');

    // What a caller gets from `indexOf` when the tapped channel was filtered
    // out of the list it passed.
    await open(tester, channel: b, channels: [a, b, c], initialIndex: -1);

    expect(find.text('bravo'), findsWidgets,
        reason: 'the channel that was tapped must be the one that opens');
    expect(find.text('alpha'), findsNothing,
        reason: '-1 must not fall through to channel 0');
  });

  testWidgets('an empty channel list does not throw and plays the one channel',
      (tester) async {
    // Every favourite filtered out, so the caller hands over an empty list.
    await open(tester, channel: ch('solo'), channels: const [], initialIndex: -1);

    expect(tester.takeException(), isNull,
        reason: 'an empty list used to RangeError on _channels[0]');
    expect(find.text('solo'), findsWidgets);
  });

  testWidgets('an out-of-range initialIndex falls back to the named channel',
      (tester) async {
    final a = ch('alpha'), b = ch('bravo');

    await open(tester, channel: b, channels: [a, b], initialIndex: 99);

    expect(tester.takeException(), isNull);
    expect(find.text('bravo'), findsWidgets);
  });

  testWidgets('a valid initialIndex is still honoured', (tester) async {
    final a = ch('alpha'), b = ch('bravo'), c = ch('charlie');

    // The normal path must be unchanged: the index wins, and it is the caller's
    // statement of the channel's real position.
    await open(tester, channel: c, channels: [a, b, c], initialIndex: 2);

    expect(find.text('charlie'), findsWidgets);
  });
}
