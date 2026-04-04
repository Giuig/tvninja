// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get loading => 'Caricamento...';

  @override
  String get welcomeToTvninja => 'Benvenuto in TV Ninja!';

  @override
  String get watchYourFavoriteChannels => 'Guarda i tuoi canali preferiti';

  @override
  String get playlists => 'Playlist';

  @override
  String get channels => 'Canali';

  @override
  String get views => 'Visualizzazioni';

  @override
  String get recentChannels => 'Canali recenti';

  @override
  String get noChannelsYet => 'Nessun canale';

  @override
  String get addPlaylistHint =>
      'Vai su Playlist per aggiungere la tua prima lista M3U8';

  @override
  String get addPlaylist => 'Aggiungi playlist';

  @override
  String get playlistName => 'Nome della playlist';

  @override
  String get playlistUrl => 'URL della playlist (M3U8)';

  @override
  String get fillAllFields => 'Compila tutti i campi';

  @override
  String playlistAdded(Object count) {
    return 'Playlist con $count canali aggiunta';
  }

  @override
  String get noPlaylists => 'Nessuna playlist';

  @override
  String get addFirstPlaylist =>
      'Tocca + per aggiungere la tua prima lista M3U8';

  @override
  String get deletePlaylist => 'Elimina playlist';

  @override
  String get confirmDeletePlaylist => 'Eliminare questa playlist?';

  @override
  String get delete => 'Elimina';

  @override
  String get noChannels => 'Nessun canale';

  @override
  String get all => 'Tutti';

  @override
  String get cancel => 'Cancella';

  @override
  String get add => 'Aggiungi';

  @override
  String get favorites => 'Preferiti';

  @override
  String get noFavorites => 'Nessun preferito';

  @override
  String get addFavoritesHint =>
      'Tocca l\'icona cuore per aggiungere ai preferiti';

  @override
  String get searchChannels => 'Cerca canali...';

  @override
  String nChannels(int count) {
    return '$count canali';
  }

  @override
  String get loadingStream => 'Caricamento stream...';

  @override
  String get audioOnly => 'Solo audio';

  @override
  String get noChannelsMatchFilter => 'Nessun canale corrisponde';

  @override
  String get removeFromFavorites => 'Rimuovere dai preferiti?';

  @override
  String removeFromFavoritesDetail(String name) {
    return 'Rimuovere \"$name\" dai preferiti?';
  }

  @override
  String get remove => 'Rimuovi';

  @override
  String get invalidUrl =>
      'URL non valido. Inserisci un URL HTTP/HTTPS valido.';

  @override
  String channelsLoaded(Object count) {
    return '$count canali caricati';
  }

  @override
  String error(String message) {
    return 'Errore: $message';
  }

  @override
  String get m3uUrl => 'M3U / URL';

  @override
  String get xtreamCodes => 'Xtream Codes';

  @override
  String get browseIptvOrg => 'Sfoglia IPTV.org';

  @override
  String get playlistNameHint => 'Il mio IPTV';

  @override
  String get portalUrl => 'URL del portale';

  @override
  String get username => 'Nome utente';

  @override
  String get password => 'Password';

  @override
  String get rename => 'Rinomina';

  @override
  String get copyUrl => 'Copia URL';

  @override
  String get urlCopied => 'URL copiato negli appunti';

  @override
  String get refresh => 'Aggiorna';

  @override
  String get renamePlaylist => 'Rinomina playlist';

  @override
  String get nameLabel => 'Nome';

  @override
  String get noChannelsFound => 'Nessun canale trovato';

  @override
  String get switchToVideo => 'Passa al video';

  @override
  String get audioOnlyMode => 'Modalità solo audio';

  @override
  String get unknownError => 'Errore sconosciuto';

  @override
  String get nativeBackgroundAudio => 'Audio in secondo piano';

  @override
  String get notificationControlsHint =>
      'Usa i controlli notifica per riprodurre/pausare';

  @override
  String get failedToLoadStream => 'Impossibile caricare lo stream';

  @override
  String get retry => 'Riprova';

  @override
  String channelsLoadedForCountry(int count, String country) {
    return '$count canali caricati per $country';
  }

  @override
  String failedToLoadCountry(String country, String error) {
    return 'Impossibile caricare $country: $error';
  }

  @override
  String get searchCountries => 'Cerca paesi...';

  @override
  String loadingCountry(String country) {
    return 'Caricamento $country...';
  }

  @override
  String get switchingToAudio => 'Passaggio all\'audio...';

  @override
  String get failedToLoad => 'Caricamento fallito';

  @override
  String get videoNotAvailable => 'Video non disponibile';

  @override
  String loadingChannels(int count) {
    return 'Caricamento $count canali...';
  }

  @override
  String errorLoadingChannels(String error) {
    return 'Errore caricamento canali: $error';
  }

  @override
  String get playlistRefreshed => 'Playlist aggiornata';

  @override
  String get renamePlaylistHint => 'Inserisci nuovo nome';

  @override
  String get deletePlaylistConfirmation =>
      'Questa playlist verrà eliminata permanentemente con tutti i canali.';

  @override
  String get copied => 'Copiato';

  @override
  String get noInternet => 'Nessuna connessione internet';

  @override
  String get streamError => 'Errore stream';

  @override
  String get tapToRetry => 'Tocca per riprovare';

  @override
  String get audioOnlyDescription =>
      'Ascolta solo audio per risparmiare batteria';

  @override
  String get switchToVideoDescription => 'Torna alla modalità video';

  @override
  String get previousChannel => 'Canale precedente';

  @override
  String get nextChannel => 'Canale successivo';

  @override
  String get closePlayer => 'Chiudi player';

  @override
  String get expandPlayer => 'Espandi player';

  @override
  String get browse => 'Sfoglia';
}
