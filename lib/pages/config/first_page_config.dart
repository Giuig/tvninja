import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/home_page.dart';
import 'package:tvninja/pages/playlist_page.dart';
import 'package:flutter/material.dart';
import 'package:ninja_material/pages/first_page.dart';
import 'package:ninja_material/l10n/app_localizations.dart' as ninja_material;

final FirstPageConfig appFirstPageConfig = FirstPageConfig(
  destinationsBuilder: appDestinationsBuilder,
  pages: appPages,
  // Opt in to ninja_material's NavigationRail on wide viewports (>=600 logical
  // px). It defaults to false in the package, so bumping the ref alone would
  // have changed nothing — this line is what actually turns it on.
  //
  // The point is landscape: the bottom bar costs ~120 logical px of height, and
  // on a phone in landscape that is roughly a third of the screen. The rail
  // moves that cost to the horizontal axis, where there is room. It switches on
  // width rather than orientation, so a tablet in portrait gets it too.
  //
  // The package stands the rail down while its side-by-side player layout is
  // active, so this cannot collide with that mode.
  responsiveNavigation: true,
);

/// Simple pages - channel tapping navigates to dedicated PlayerPage
final List<Widget> appPages = [
  const HomePage(),
  PlaylistPage(),
];

List<NavigationDestination> appDestinationsBuilder(BuildContext context) {
  return [
    NavigationDestination(
      selectedIcon: Icon(Icons.home),
      icon: Icon(Icons.home_outlined),
      label: ninja_material.AppLocalizations.of(context)!.home,
    ),
    NavigationDestination(
      selectedIcon: Icon(Icons.playlist_play),
      icon: Icon(Icons.playlist_play_outlined),
      label: AppLocalizations.of(context)!.playlists,
    ),
  ];
}
