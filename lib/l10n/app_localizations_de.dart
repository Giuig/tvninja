// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get loading => 'Laden...';

  @override
  String get fillScreen => 'Fill screen';

  @override
  String get originalSize => 'Original size';

  @override
  String get welcomeToTvninja => 'Willkommen bei TV Ninja!';

  @override
  String get watchYourFavoriteChannels =>
      'Schauen Sie Ihre Lieblings-TV-Sender';

  @override
  String get playlists => 'Wiedergabelisten';

  @override
  String get channels => 'Kanäle';

  @override
  String get views => 'Aufrufe';

  @override
  String get recentChannels => 'Letzte Kanäle';

  @override
  String get noChannelsYet => 'Noch keine Kanäle';

  @override
  String get addPlaylistHint =>
      'Gehen Sie zu Wiedergabelisten, um Ihre erste M3U8-Liste hinzuzufügen';

  @override
  String get addPlaylist => 'Wiedergabeliste hinzufügen';

  @override
  String get playlistName => 'Name der Wiedergabeliste';

  @override
  String get playlistUrl => 'Playlist-URL (M3U8)';

  @override
  String get fillAllFields => 'Bitte füllen Sie alle Felder aus';

  @override
  String playlistAdded(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Wiedergabeliste mit $count Kanälen hinzugefügt',
      one: 'Wiedergabeliste mit $count Kanal hinzugefügt',
    );
    return '$_temp0';
  }

  @override
  String get noPlaylists => 'Noch keine Wiedergabelisten';

  @override
  String get addFirstPlaylist =>
      'Tippen Sie auf +, um Ihre erste M3U8-Liste hinzuzufügen';

  @override
  String get deletePlaylist => 'Wiedergabeliste löschen';

  @override
  String get confirmDeletePlaylist => 'Wirklich löschen?';

  @override
  String get delete => 'Löschen';

  @override
  String get noChannels => 'Keine Kanäle';

  @override
  String get all => 'Alle';

  @override
  String get cancel => 'Abbrechen';

  @override
  String get add => 'Hinzufügen';

  @override
  String get favorites => 'Favoriten';

  @override
  String get noFavorites => 'Keine Favoriten';

  @override
  String get addFavoritesHint => 'Tippen Sie auf das Herz-Symbol';

  @override
  String get searchChannels => 'Kanäle suchen...';

  @override
  String nChannels(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Kanäle',
      one: '$count Kanal',
    );
    return '$_temp0';
  }

  @override
  String get loadingStream => 'Stream wird geladen...';

  @override
  String get audioOnly => 'Nur Audio';

  @override
  String get noChannelsMatchFilter => 'Keine Kanäle entsprechen dem Filter';

  @override
  String get removeFromFavorites => 'Aus Favoriten entfernen?';

  @override
  String removeFromFavoritesDetail(String name) {
    return '\"$name\" aus Favoriten entfernen?';
  }

  @override
  String get remove => 'Entfernen';

  @override
  String get invalidUrl =>
      'Ungültige URL. Bitte geben Sie eine gültige HTTP/HTTPS-URL ein.';

  @override
  String channelsLoaded(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Kanäle geladen',
      one: '$count Kanal geladen',
    );
    return '$_temp0';
  }

  @override
  String error(String message) {
    return 'Fehler: $message';
  }

  @override
  String get m3uUrl => 'M3U / URL';

  @override
  String get xtreamCodes => 'Xtream Codes';

  @override
  String get browseIptvOrg => 'IPTV.org durchsuchen';

  @override
  String get playlistNameHint => 'Mein IPTV';

  @override
  String get portalUrl => 'Portal-URL';

  @override
  String get username => 'Benutzername';

  @override
  String get password => 'Passwort';

  @override
  String get rename => 'Umbenennen';

  @override
  String get copyUrl => 'URL kopieren';

  @override
  String get urlCopied => 'URL in Zwischenablage kopiert';

  @override
  String get refresh => 'Aktualisieren';

  @override
  String get renamePlaylist => 'Wiedergabeliste umbenennen';

  @override
  String get nameLabel => 'Name';

  @override
  String get noChannelsFound => 'Keine Kanäle gefunden';

  @override
  String get switchToVideo => 'Zu Video wechseln';

  @override
  String get audioOnlyMode => 'Nur-Audio-Modus';

  @override
  String get unknownError => 'Unbekannter Fehler';

  @override
  String get nativeBackgroundAudio => 'Hintergrund-Audio';

  @override
  String get notificationControlsHint =>
      'Benachrichtigungssteuerung zum Abspielen/Pausieren verwenden';

  @override
  String get failedToLoadStream => 'Stream konnte nicht geladen werden';

  @override
  String get retry => 'Wiederholen';

  @override
  String channelsLoadedForCountry(int count, String country) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Kanäle für $country geladen',
      one: '$count Kanal für $country geladen',
    );
    return '$_temp0';
  }

  @override
  String failedToLoadCountry(String country, String error) {
    return '$country konnte nicht geladen werden: $error';
  }

  @override
  String get searchCountries => 'Länder suchen...';

  @override
  String loadingCountry(String country) {
    return '$country wird geladen...';
  }

  @override
  String get switchingToAudio => 'Wechsel zu Audio...';

  @override
  String get failedToLoad => 'Laden fehlgeschlagen';

  @override
  String get videoNotAvailable => 'Video nicht verfügbar';

  @override
  String loadingChannels(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Kanäle werden geladen...',
      one: '$count Kanal wird geladen...',
    );
    return '$_temp0';
  }

  @override
  String errorLoadingChannels(String error) {
    return 'Fehler beim Laden der Kanäle: $error';
  }

  @override
  String get playlistRefreshed => 'Wiedergabeliste aktualisiert';

  @override
  String get renamePlaylistHint => 'Neuen Namen eingeben';

  @override
  String get deletePlaylistConfirmation =>
      'Dauerhaft löschen? Alle Kanäle gehen verloren.';

  @override
  String get copied => 'Kopiert';

  @override
  String get noInternet => 'Keine Internetverbindung';

  @override
  String get streamError => 'Stream-Fehler';

  @override
  String get tapToRetry => 'Tippen zum Wiederholen';

  @override
  String get audioOnlyDescription =>
      'Nur Audio abspielen um Batterie zu sparen';

  @override
  String get switchToVideoDescription => 'Zurück zum Videomodus wechseln';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get fullscreen => 'Fullscreen';

  @override
  String get exitFullscreen => 'Exit fullscreen';

  @override
  String get previousChannel => 'Vorheriger Kanal';

  @override
  String get nextChannel => 'Nächster Kanal';

  @override
  String get closePlayer => 'Player schließen';

  @override
  String get expandPlayer => 'Player vergrößern';

  @override
  String get browse => 'Durchsuchen';

  @override
  String get playlistAlreadyAdded => 'That playlist is already added';
}
