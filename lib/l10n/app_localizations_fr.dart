// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get loading => 'Chargement...';

  @override
  String get welcomeToTvninja => 'Bienvenue dans TV Ninja!';

  @override
  String get watchYourFavoriteChannels => 'Regardez vos chaînes préférées';

  @override
  String get playlists => 'Listes';

  @override
  String get channels => 'Chaînes';

  @override
  String get views => 'Vues';

  @override
  String get recentChannels => 'Chaînes récentes';

  @override
  String get noChannelsYet => 'Pas de chaînes';

  @override
  String get addPlaylistHint =>
      'Allez dans Listes pour ajouter votre première playlist M3U8';

  @override
  String get addPlaylist => 'Ajouter une liste';

  @override
  String get playlistName => 'Nom de la liste';

  @override
  String get playlistUrl => 'URL de la liste (M3U8)';

  @override
  String get fillAllFields => 'Remplissez tous les champs';

  @override
  String playlistAdded(Object count) {
    return 'Liste avec $count chaînes ajoutée';
  }

  @override
  String get noPlaylists => 'Pas de listes';

  @override
  String get addFirstPlaylist =>
      'Appuyez sur + pour ajouter votre première playlist M3U8';

  @override
  String get deletePlaylist => 'Supprimer la liste';

  @override
  String get confirmDeletePlaylist => 'Supprimer cette liste ?';

  @override
  String get delete => 'Supprimer';

  @override
  String get noChannels => 'Pas de chaînes';

  @override
  String get all => 'Tous';

  @override
  String get cancel => 'Annuler';

  @override
  String get add => 'Ajouter';

  @override
  String get favorites => 'Favoris';

  @override
  String get noFavorites => 'Pas de favoris';

  @override
  String get addFavoritesHint =>
      'Appuyez sur l\'icône cœur pour ajouter aux favoris';

  @override
  String get searchChannels => 'Rechercher des chaînes...';

  @override
  String nChannels(int count) {
    return '$count chaînes';
  }

  @override
  String get loadingStream => 'Chargement du stream...';

  @override
  String get audioOnly => 'Audio seul';

  @override
  String get noChannelsMatchFilter => 'Aucune chaîne ne correspond';

  @override
  String get removeFromFavorites => 'Retirer des favoris ?';

  @override
  String removeFromFavoritesDetail(String name) {
    return 'Retirer \"$name\" des favoris ?';
  }

  @override
  String get remove => 'Retirer';

  @override
  String get invalidUrl => 'URL invalide. Entrez une URL HTTP/HTTPS valide.';

  @override
  String channelsLoaded(Object count) {
    return '$count chaînes chargées';
  }

  @override
  String error(String message) {
    return 'Erreur : $message';
  }

  @override
  String get m3uUrl => 'M3U / URL';

  @override
  String get xtreamCodes => 'Xtream Codes';

  @override
  String get browseIptvOrg => 'Parcourir IPTV.org';

  @override
  String get playlistNameHint => 'Mon IPTV';

  @override
  String get portalUrl => 'URL du portail';

  @override
  String get username => 'Nom d\'utilisateur';

  @override
  String get password => 'Mot de passe';

  @override
  String get rename => 'Renommer';

  @override
  String get copyUrl => 'Copier l\'URL';

  @override
  String get urlCopied => 'URL copiée dans le presse-papiers';

  @override
  String get refresh => 'Actualiser';

  @override
  String get renamePlaylist => 'Renommer la liste';

  @override
  String get nameLabel => 'Nom';

  @override
  String get noChannelsFound => 'Aucune chaîne trouvée';

  @override
  String get switchToVideo => 'Passer à la vidéo';

  @override
  String get audioOnlyMode => 'Mode audio uniquement';

  @override
  String get unknownError => 'Erreur inconnue';

  @override
  String get nativeBackgroundAudio => 'Audio en arrière-plan';

  @override
  String get notificationControlsHint =>
      'Utilisez les contrôles de notification pour lire/mettre en pause';

  @override
  String get failedToLoadStream => 'Échec du chargement du stream';

  @override
  String get retry => 'Réessayer';

  @override
  String channelsLoadedForCountry(int count, String country) {
    return '$count chaînes chargées pour $country';
  }

  @override
  String failedToLoadCountry(String country, String error) {
    return 'Échec du chargement de $country : $error';
  }

  @override
  String get searchCountries => 'Rechercher des pays...';

  @override
  String loadingCountry(String country) {
    return 'Chargement de $country...';
  }

  @override
  String get switchingToAudio => 'Passage à l\'audio...';

  @override
  String get failedToLoad => 'Échec du chargement';

  @override
  String get videoNotAvailable => 'Vidéo non disponible';

  @override
  String loadingChannels(int count) {
    return 'Chargement de $count chaînes...';
  }

  @override
  String errorLoadingChannels(String error) {
    return 'Erreur lors du chargement : $error';
  }

  @override
  String get playlistRefreshed => 'Liste actualisée';

  @override
  String get renamePlaylistHint => 'Entrez le nouveau nom';

  @override
  String get deletePlaylistConfirmation =>
      'Cela supprimera définitivement cette liste et toutes ses chaînes.';

  @override
  String get copied => 'Copié';

  @override
  String get noInternet => 'Pas de connexion internet';

  @override
  String get streamError => 'Erreur de stream';

  @override
  String get tapToRetry => 'Appuyez pour réessayer';

  @override
  String get audioOnlyDescription =>
      'Écoutez l\'audio uniquement pour économiser la batterie';

  @override
  String get switchToVideoDescription => 'Revenir au mode vidéo';

  @override
  String get previousChannel => 'Chaîne précédente';

  @override
  String get nextChannel => 'Chaîne suivante';

  @override
  String get closePlayer => 'Fermer le lecteur';

  @override
  String get expandPlayer => 'Agrandir le lecteur';

  @override
  String get browse => 'Parcourir';
}
