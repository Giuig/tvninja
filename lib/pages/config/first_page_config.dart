import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/home_page.dart';
import 'package:tvninja/pages/playlist_page.dart';
import 'package:flutter/material.dart';
import 'package:ninja_material/pages/first_page.dart';
import 'package:ninja_material/l10n/app_localizations.dart' as ninja_material;

final FirstPageConfig appFirstPageConfig = FirstPageConfig(
  destinationsBuilder: appDestinationsBuilder,
  pages: appPages,
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
