// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get loading => 'Loading...';

  @override
  String get welcomeToTvninja => 'Welcome to TV Ninja!';

  @override
  String get watchYourFavoriteChannels => 'Watch your favorite TV channels';

  @override
  String get playlists => 'Playlists';

  @override
  String get channels => 'Channels';

  @override
  String get views => 'Views';

  @override
  String get recentChannels => 'Recent Channels';

  @override
  String get noChannelsYet => 'No channels yet';

  @override
  String get addPlaylistHint =>
      'Go to Playlists to add your first M3U8 playlist';

  @override
  String get addPlaylist => 'Add Playlist';

  @override
  String get playlistName => 'Playlist Name';

  @override
  String get playlistUrl => 'Playlist URL (M3U8)';

  @override
  String get fillAllFields => 'Please fill in all fields';

  @override
  String playlistAdded(Object count) {
    return 'Playlist added with $count channels';
  }

  @override
  String get noPlaylists => 'No playlists yet';

  @override
  String get addFirstPlaylist => 'Tap + to add your first M3U8 playlist';

  @override
  String get deletePlaylist => 'Delete Playlist';

  @override
  String get confirmDeletePlaylist =>
      'Are you sure you want to delete this playlist?';

  @override
  String get delete => 'Delete';

  @override
  String get noChannels => 'No channels in this playlist';

  @override
  String get all => 'All';

  @override
  String get cancel => 'Cancel';

  @override
  String get add => 'Add';

  @override
  String get favorites => 'Favorites';

  @override
  String get noFavorites => 'No favorites yet';

  @override
  String get addFavoritesHint =>
      'Tap the heart icon on any channel to add it to your favorites';

  @override
  String get searchChannels => 'Search channels...';

  @override
  String nChannels(int count) {
    return '$count channels';
  }

  @override
  String get loadingStream => 'Loading stream...';

  @override
  String get audioOnly => 'Audio Only';

  @override
  String get noChannelsMatchFilter => 'No channels match your filter';

  @override
  String get removeFromFavorites => 'Remove from favorites?';

  @override
  String removeFromFavoritesDetail(String name) {
    return 'Remove \"$name\" from your favorites?';
  }

  @override
  String get remove => 'Remove';

  @override
  String get invalidUrl => 'Invalid URL. Please enter a valid HTTP/HTTPS URL.';

  @override
  String channelsLoaded(Object count) {
    return '$count channels loaded';
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
  String get browseIptvOrg => 'Browse IPTV.org';

  @override
  String get playlistNameHint => 'My IPTV';

  @override
  String get portalUrl => 'Portal URL';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get rename => 'Rename';

  @override
  String get copyUrl => 'Copy URL';

  @override
  String get urlCopied => 'URL copied to clipboard';

  @override
  String get refresh => 'Refresh';

  @override
  String get renamePlaylist => 'Rename Playlist';

  @override
  String get nameLabel => 'Name';

  @override
  String get noChannelsFound => 'No channels found';

  @override
  String get switchToVideo => 'Switch to Video';

  @override
  String get audioOnlyMode => 'Audio Only Mode';

  @override
  String get unknownError => 'Unknown error';

  @override
  String get nativeBackgroundAudio => 'Native Background Audio';

  @override
  String get notificationControlsHint =>
      'Use notification controls to play/pause';

  @override
  String get failedToLoadStream => 'Failed to load stream';

  @override
  String get retry => 'Retry';

  @override
  String channelsLoadedForCountry(int count, String country) {
    return '$count channels loaded for $country';
  }

  @override
  String failedToLoadCountry(String country, String error) {
    return 'Failed to load $country: $error';
  }

  @override
  String get searchCountries => 'Search countries...';

  @override
  String loadingCountry(String country) {
    return 'Loading $country...';
  }

  @override
  String get switchingToAudio => 'Switching to audio...';

  @override
  String get failedToLoad => 'Failed to load';

  @override
  String get videoNotAvailable => 'Video not available';

  @override
  String loadingChannels(int count) {
    return 'Loading $count channels...';
  }

  @override
  String errorLoadingChannels(String error) {
    return 'Error loading channels: $error';
  }

  @override
  String get playlistRefreshed => 'Playlist refreshed';

  @override
  String get renamePlaylistHint => 'Enter new name';

  @override
  String get deletePlaylistConfirmation =>
      'This will permanently delete this playlist and all its channels.';

  @override
  String get copied => 'Copied';

  @override
  String get noInternet => 'No internet connection';

  @override
  String get streamError => 'Stream error';

  @override
  String get tapToRetry => 'Tap to retry';

  @override
  String get audioOnlyDescription => 'Listen to audio only to save battery';

  @override
  String get switchToVideoDescription => 'Switch back to video mode';

  @override
  String get previousChannel => 'Previous channel';

  @override
  String get nextChannel => 'Next channel';

  @override
  String get closePlayer => 'Close player';

  @override
  String get expandPlayer => 'Expand player';

  @override
  String get browse => 'Browse';
}
