import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_it.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('it'),
    Locale('ja')
  ];

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @welcomeToTvninja.
  ///
  /// In en, this message translates to:
  /// **'Welcome to TV Ninja!'**
  String get welcomeToTvninja;

  /// No description provided for @watchYourFavoriteChannels.
  ///
  /// In en, this message translates to:
  /// **'Watch your favorite TV channels'**
  String get watchYourFavoriteChannels;

  /// No description provided for @playlists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get playlists;

  /// No description provided for @channels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get channels;

  /// No description provided for @views.
  ///
  /// In en, this message translates to:
  /// **'Views'**
  String get views;

  /// No description provided for @recentChannels.
  ///
  /// In en, this message translates to:
  /// **'Recent Channels'**
  String get recentChannels;

  /// No description provided for @noChannelsYet.
  ///
  /// In en, this message translates to:
  /// **'No channels yet'**
  String get noChannelsYet;

  /// No description provided for @addPlaylistHint.
  ///
  /// In en, this message translates to:
  /// **'Go to Playlists to add your first M3U8 playlist'**
  String get addPlaylistHint;

  /// No description provided for @addPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add Playlist'**
  String get addPlaylist;

  /// No description provided for @playlistName.
  ///
  /// In en, this message translates to:
  /// **'Playlist Name'**
  String get playlistName;

  /// No description provided for @playlistUrl.
  ///
  /// In en, this message translates to:
  /// **'Playlist URL (M3U8)'**
  String get playlistUrl;

  /// No description provided for @fillAllFields.
  ///
  /// In en, this message translates to:
  /// **'Please fill in all fields'**
  String get fillAllFields;

  /// No description provided for @playlistAdded.
  ///
  /// In en, this message translates to:
  /// **'Playlist added with {count} channels'**
  String playlistAdded(Object count);

  /// No description provided for @noPlaylists.
  ///
  /// In en, this message translates to:
  /// **'No playlists yet'**
  String get noPlaylists;

  /// No description provided for @addFirstPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Tap + to add your first M3U8 playlist'**
  String get addFirstPlaylist;

  /// No description provided for @deletePlaylist.
  ///
  /// In en, this message translates to:
  /// **'Delete Playlist'**
  String get deletePlaylist;

  /// No description provided for @confirmDeletePlaylist.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this playlist?'**
  String get confirmDeletePlaylist;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @noChannels.
  ///
  /// In en, this message translates to:
  /// **'No channels in this playlist'**
  String get noChannels;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @favorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favorites;

  /// No description provided for @noFavorites.
  ///
  /// In en, this message translates to:
  /// **'No favorites yet'**
  String get noFavorites;

  /// No description provided for @addFavoritesHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the heart icon on any channel to add it to your favorites'**
  String get addFavoritesHint;

  /// No description provided for @searchChannels.
  ///
  /// In en, this message translates to:
  /// **'Search channels...'**
  String get searchChannels;

  /// No description provided for @nChannels.
  ///
  /// In en, this message translates to:
  /// **'{count} channels'**
  String nChannels(int count);

  /// No description provided for @loadingStream.
  ///
  /// In en, this message translates to:
  /// **'Loading stream...'**
  String get loadingStream;

  /// No description provided for @audioOnly.
  ///
  /// In en, this message translates to:
  /// **'Audio Only'**
  String get audioOnly;

  /// No description provided for @noChannelsMatchFilter.
  ///
  /// In en, this message translates to:
  /// **'No channels match your filter'**
  String get noChannelsMatchFilter;

  /// No description provided for @removeFromFavorites.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites?'**
  String get removeFromFavorites;

  /// No description provided for @removeFromFavoritesDetail.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" from your favorites?'**
  String removeFromFavoritesDetail(String name);

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @invalidUrl.
  ///
  /// In en, this message translates to:
  /// **'Invalid URL. Please enter a valid HTTP/HTTPS URL.'**
  String get invalidUrl;

  /// No description provided for @channelsLoaded.
  ///
  /// In en, this message translates to:
  /// **'{count} channels loaded'**
  String channelsLoaded(Object count);

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String error(String message);

  /// No description provided for @m3uUrl.
  ///
  /// In en, this message translates to:
  /// **'M3U / URL'**
  String get m3uUrl;

  /// No description provided for @xtreamCodes.
  ///
  /// In en, this message translates to:
  /// **'Xtream Codes'**
  String get xtreamCodes;

  /// Title for browsing IPTV.org content
  ///
  /// In en, this message translates to:
  /// **'Browse IPTV.org'**
  String get browseIptvOrg;

  /// No description provided for @playlistNameHint.
  ///
  /// In en, this message translates to:
  /// **'My IPTV'**
  String get playlistNameHint;

  /// No description provided for @portalUrl.
  ///
  /// In en, this message translates to:
  /// **'Portal URL'**
  String get portalUrl;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @copyUrl.
  ///
  /// In en, this message translates to:
  /// **'Copy URL'**
  String get copyUrl;

  /// No description provided for @urlCopied.
  ///
  /// In en, this message translates to:
  /// **'URL copied to clipboard'**
  String get urlCopied;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @renamePlaylist.
  ///
  /// In en, this message translates to:
  /// **'Rename Playlist'**
  String get renamePlaylist;

  /// No description provided for @nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get nameLabel;

  /// No description provided for @noChannelsFound.
  ///
  /// In en, this message translates to:
  /// **'No channels found'**
  String get noChannelsFound;

  /// No description provided for @switchToVideo.
  ///
  /// In en, this message translates to:
  /// **'Switch to Video'**
  String get switchToVideo;

  /// No description provided for @audioOnlyMode.
  ///
  /// In en, this message translates to:
  /// **'Audio Only Mode'**
  String get audioOnlyMode;

  /// No description provided for @unknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error'**
  String get unknownError;

  /// No description provided for @nativeBackgroundAudio.
  ///
  /// In en, this message translates to:
  /// **'Native Background Audio'**
  String get nativeBackgroundAudio;

  /// No description provided for @notificationControlsHint.
  ///
  /// In en, this message translates to:
  /// **'Use notification controls to play/pause'**
  String get notificationControlsHint;

  /// No description provided for @failedToLoadStream.
  ///
  /// In en, this message translates to:
  /// **'Failed to load stream'**
  String get failedToLoadStream;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @channelsLoadedForCountry.
  ///
  /// In en, this message translates to:
  /// **'{count} channels loaded for {country}'**
  String channelsLoadedForCountry(int count, String country);

  /// No description provided for @failedToLoadCountry.
  ///
  /// In en, this message translates to:
  /// **'Failed to load {country}: {error}'**
  String failedToLoadCountry(String country, String error);

  /// No description provided for @searchCountries.
  ///
  /// In en, this message translates to:
  /// **'Search countries...'**
  String get searchCountries;

  /// No description provided for @loadingCountry.
  ///
  /// In en, this message translates to:
  /// **'Loading {country}...'**
  String loadingCountry(String country);

  /// No description provided for @switchingToAudio.
  ///
  /// In en, this message translates to:
  /// **'Switching to audio...'**
  String get switchingToAudio;

  /// No description provided for @failedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get failedToLoad;

  /// No description provided for @videoNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Video not available'**
  String get videoNotAvailable;

  /// No description provided for @loadingChannels.
  ///
  /// In en, this message translates to:
  /// **'Loading {count} channels...'**
  String loadingChannels(int count);

  /// No description provided for @errorLoadingChannels.
  ///
  /// In en, this message translates to:
  /// **'Error loading channels: {error}'**
  String errorLoadingChannels(String error);

  /// No description provided for @playlistRefreshed.
  ///
  /// In en, this message translates to:
  /// **'Playlist refreshed'**
  String get playlistRefreshed;

  /// No description provided for @renamePlaylistHint.
  ///
  /// In en, this message translates to:
  /// **'Enter new name'**
  String get renamePlaylistHint;

  /// No description provided for @deletePlaylistConfirmation.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete this playlist and all its channels.'**
  String get deletePlaylistConfirmation;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @noInternet.
  ///
  /// In en, this message translates to:
  /// **'No internet connection'**
  String get noInternet;

  /// No description provided for @streamError.
  ///
  /// In en, this message translates to:
  /// **'Stream error'**
  String get streamError;

  /// No description provided for @tapToRetry.
  ///
  /// In en, this message translates to:
  /// **'Tap to retry'**
  String get tapToRetry;

  /// No description provided for @audioOnlyDescription.
  ///
  /// In en, this message translates to:
  /// **'Listen to audio only to save battery'**
  String get audioOnlyDescription;

  /// No description provided for @switchToVideoDescription.
  ///
  /// In en, this message translates to:
  /// **'Switch back to video mode'**
  String get switchToVideoDescription;

  /// No description provided for @previousChannel.
  ///
  /// In en, this message translates to:
  /// **'Previous channel'**
  String get previousChannel;

  /// No description provided for @nextChannel.
  ///
  /// In en, this message translates to:
  /// **'Next channel'**
  String get nextChannel;

  /// No description provided for @closePlayer.
  ///
  /// In en, this message translates to:
  /// **'Close player'**
  String get closePlayer;

  /// No description provided for @expandPlayer.
  ///
  /// In en, this message translates to:
  /// **'Expand player'**
  String get expandPlayer;

  /// No description provided for @browse.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get browse;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
        'de',
        'en',
        'es',
        'fr',
        'it',
        'ja'
      ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'it':
      return AppLocalizationsIt();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
