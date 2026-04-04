// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get loading => 'Cargando...';

  @override
  String get welcomeToTvninja => '¡Bienvenido a TV Ninja!';

  @override
  String get watchYourFavoriteChannels => 'Mira tus canales favoritos';

  @override
  String get playlists => 'Listas';

  @override
  String get channels => 'Canales';

  @override
  String get views => 'Vistas';

  @override
  String get recentChannels => 'Canales recientes';

  @override
  String get noChannelsYet => 'Sin canales';

  @override
  String get addPlaylistHint =>
      'Ve a Listas para agregar tu primera lista M3U8';

  @override
  String get addPlaylist => 'Agregar lista';

  @override
  String get playlistName => 'Nombre de la lista';

  @override
  String get playlistUrl => 'URL de la lista (M3U8)';

  @override
  String get fillAllFields => 'Completa todos los campos';

  @override
  String playlistAdded(Object count) {
    return 'Lista con $count canales agregada';
  }

  @override
  String get noPlaylists => 'Sin listas';

  @override
  String get addFirstPlaylist => 'Toca + para agregar tu primera lista M3U8';

  @override
  String get deletePlaylist => 'Eliminar lista';

  @override
  String get confirmDeletePlaylist => '¿Eliminar esta lista?';

  @override
  String get delete => 'Eliminar';

  @override
  String get noChannels => 'Sin canales';

  @override
  String get all => 'Todos';

  @override
  String get cancel => 'Cancelar';

  @override
  String get add => 'Agregar';

  @override
  String get favorites => 'Favoritos';

  @override
  String get noFavorites => 'Sin favoritos';

  @override
  String get addFavoritesHint =>
      'Toca el ícono de corazón para agregar a favoritos';

  @override
  String get searchChannels => 'Buscar canales...';

  @override
  String nChannels(int count) {
    return '$count canales';
  }

  @override
  String get loadingStream => 'Cargando stream...';

  @override
  String get audioOnly => 'Solo audio';

  @override
  String get noChannelsMatchFilter => 'Ningún canal coincide';

  @override
  String get removeFromFavorites => '¿Quitar de favoritos?';

  @override
  String removeFromFavoritesDetail(String name) {
    return '¿Quitar \"$name\" de favoritos?';
  }

  @override
  String get remove => 'Quitar';

  @override
  String get invalidUrl => 'URL inválida. Ingresa una URL HTTP/HTTPS válida.';

  @override
  String channelsLoaded(Object count) {
    return '$count canales cargados';
  }

  @override
  String error(String message) {
    return 'Error: $message';
  }

  @override
  String get m3uUrl => 'M3U / URL';

  @override
  String get xtreamCodes => 'Xtream Codes';

  @override
  String get browseIptvOrg => 'Explorar IPTV.org';

  @override
  String get playlistNameHint => 'Mi IPTV';

  @override
  String get portalUrl => 'URL del portal';

  @override
  String get username => 'Usuario';

  @override
  String get password => 'Contraseña';

  @override
  String get rename => 'Renombrar';

  @override
  String get copyUrl => 'Copiar URL';

  @override
  String get urlCopied => 'URL copiada al portapapeles';

  @override
  String get refresh => 'Actualizar';

  @override
  String get renamePlaylist => 'Renombrar lista';

  @override
  String get nameLabel => 'Nombre';

  @override
  String get noChannelsFound => 'No se encontraron canales';

  @override
  String get switchToVideo => 'Cambiar a video';

  @override
  String get audioOnlyMode => 'Modo solo audio';

  @override
  String get unknownError => 'Error desconocido';

  @override
  String get nativeBackgroundAudio => 'Audio en segundo plano';

  @override
  String get notificationControlsHint =>
      'Usa los controles de notificación para reproducir/pausar';

  @override
  String get failedToLoadStream => 'Error al cargar el stream';

  @override
  String get retry => 'Reintentar';

  @override
  String channelsLoadedForCountry(int count, String country) {
    return '$count canales cargados para $country';
  }

  @override
  String failedToLoadCountry(String country, String error) {
    return 'Error al cargar $country: $error';
  }

  @override
  String get searchCountries => 'Buscar países...';

  @override
  String loadingCountry(String country) {
    return 'Cargando $country...';
  }

  @override
  String get switchingToAudio => 'Cambiando a audio...';

  @override
  String get failedToLoad => 'Error al cargar';

  @override
  String get videoNotAvailable => 'Video no disponible';

  @override
  String loadingChannels(int count) {
    return 'Cargando $count canales...';
  }

  @override
  String errorLoadingChannels(String error) {
    return 'Error al cargar canales: $error';
  }

  @override
  String get playlistRefreshed => 'Lista actualizada';

  @override
  String get renamePlaylistHint => 'Ingresa nuevo nombre';

  @override
  String get deletePlaylistConfirmation =>
      'Esto eliminará permanentemente esta lista y todos sus canales.';

  @override
  String get copied => 'Copiado';

  @override
  String get noInternet => 'Sin conexión a internet';

  @override
  String get streamError => 'Error de stream';

  @override
  String get tapToRetry => 'Toca para reintentar';

  @override
  String get audioOnlyDescription => 'Escucha solo audio para ahorrar batería';

  @override
  String get switchToVideoDescription => 'Volver al modo video';

  @override
  String get previousChannel => 'Canal anterior';

  @override
  String get nextChannel => 'Siguiente canal';

  @override
  String get closePlayer => 'Cerrar reproductor';

  @override
  String get expandPlayer => 'Expandir reproductor';

  @override
  String get browse => 'Explorar';
}
