import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/config/first_page_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ninja_material/bootstrap.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Namespace this app's stored preferences. WEB ONLY, and it must stay the
  // first thing that happens.
  //
  // Every ninja app is served from the same origin —
  // https://giuig.github.io/<app>/ — and browser storage is scoped to the
  // ORIGIN, not the path. `shared_preferences` writes every key with a flat
  // `flutter.` prefix, so the apps shared one key space and silently
  // overwrote each other: picking a theme colour in one repainted the others,
  // and `favorites` collided outright (this app stores channel ids there,
  // auraninja stores sound paths).
  //
  // Native is deliberately excluded. Each platform app already has its own
  // sandbox, so the collision cannot happen there — and changing the prefix
  // on Android would orphan every existing user's playlists and favourites.
  // Web users lose their stored settings once, which is the accepted cost of
  // ending the collision.
  //
  // `setPrefix` throws a StateError once anything has called
  // `SharedPreferences.getInstance()`, so it cannot move below
  // `runNinjaApp` — `initializeGlobals` reads preferences.
  if (kIsWeb) {
    SharedPreferences.setPrefix('tvninja.');
  }

  MediaKit.ensureInitialized();

  runNinjaApp(
    defaultSeedColor: Colors.indigo.shade400,
    specificLocalizationDelegate: AppLocalizations.delegate,
    appFirstPageConfig: appFirstPageConfig,
    additionalFunctions: [initializeGlobals],
    additionalProviders: [
      ChangeNotifierProvider<AppStatsNotifier>(
        create: (_) => appStatsNotifier,
      ),
    ],
  );
}
