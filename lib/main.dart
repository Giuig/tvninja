import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/config/first_page_config.dart';
import 'package:tvninja/services/live_player_notifier.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ninja_material/bootstrap.dart';
import 'package:provider/provider.dart';

final livePlayerNotifier = LivePlayerNotifier();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      ChangeNotifierProvider<LivePlayerNotifier>(
        create: (_) => livePlayerNotifier,
      ),
    ],
  );
}
