// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get loading => '読み込み中...';

  @override
  String get welcomeToTvninja => 'TV Ninjaへようこそ！';

  @override
  String get watchYourFavoriteChannels => 'お気に入りのTVを見る';

  @override
  String get playlists => 'プレイリスト';

  @override
  String get channels => 'チャンネル';

  @override
  String get views => '視聴数';

  @override
  String get recentChannels => '最近のチャンネル';

  @override
  String get noChannelsYet => 'チャンネルなし';

  @override
  String get addPlaylistHint => '最初のM3U8プレイリストを追加';

  @override
  String get addPlaylist => 'プレイリスト追加';

  @override
  String get playlistName => 'プレイリスト名';

  @override
  String get playlistUrl => 'プレイリストURL (M3U8)';

  @override
  String get fillAllFields => 'すべての項目を入力してください';

  @override
  String playlistAdded(Object count) {
    return '$countチャンネルのプレイリストを追加';
  }

  @override
  String get noPlaylists => 'プレイリストなし';

  @override
  String get addFirstPlaylist => '+をタップして最初のM3U8プレイリストを追加';

  @override
  String get deletePlaylist => 'プレイリスト削除';

  @override
  String get confirmDeletePlaylist => 'このプレイリストを削除しますか？';

  @override
  String get delete => '削除';

  @override
  String get noChannels => 'チャンネルなし';

  @override
  String get all => 'すべて';

  @override
  String get cancel => 'キャンセル';

  @override
  String get add => '追加';

  @override
  String get favorites => 'お気に入り';

  @override
  String get noFavorites => 'お気に入りなし';

  @override
  String get addFavoritesHint => 'ハートアイコンをタップしてお気に入りに追加';

  @override
  String get searchChannels => 'チャンネルを検索...';

  @override
  String nChannels(int count) {
    return '$countチャンネル';
  }

  @override
  String get loadingStream => 'ストリーム読み込み中...';

  @override
  String get audioOnly => '音声のみ';

  @override
  String get noChannelsMatchFilter => '条件に一致するチャンネルなし';

  @override
  String get removeFromFavorites => 'お気に入りから削除？';

  @override
  String removeFromFavoritesDetail(String name) {
    return '「$name」をお気に入りから削除？';
  }

  @override
  String get remove => '削除';

  @override
  String get invalidUrl => '無効なURLです。有効なHTTP/HTTPS URLを入力してください。';

  @override
  String channelsLoaded(Object count) {
    return '$countチャンネル読み込み完了';
  }

  @override
  String error(String message) {
    return 'エラー: $message';
  }

  @override
  String get m3uUrl => 'M3U / URL';

  @override
  String get xtreamCodes => 'Xtream Codes';

  @override
  String get browseIptvOrg => 'IPTV.orgをブラウズ';

  @override
  String get playlistNameHint => 'マイIPTV';

  @override
  String get portalUrl => 'ポータルURL';

  @override
  String get username => 'ユーザー名';

  @override
  String get password => 'パスワード';

  @override
  String get rename => '名前を変更';

  @override
  String get copyUrl => 'URLをコピー';

  @override
  String get urlCopied => 'URLをクリップボードにコピーしました';

  @override
  String get refresh => '更新';

  @override
  String get renamePlaylist => 'プレイリスト名を変更';

  @override
  String get nameLabel => '名前';

  @override
  String get noChannelsFound => 'チャンネルが見つかりません';

  @override
  String get switchToVideo => '動画に切り替え';

  @override
  String get audioOnlyMode => '音声のみモード';

  @override
  String get unknownError => '不明なエラー';

  @override
  String get nativeBackgroundAudio => 'バックグラウンド再生';

  @override
  String get notificationControlsHint => '通知コントロールで再生/一時停止';

  @override
  String get failedToLoadStream => 'ストリームの読み込みに失敗しました';

  @override
  String get retry => '再試行';

  @override
  String channelsLoadedForCountry(int count, String country) {
    return '$countryの$countチャンネルを読み込みました';
  }

  @override
  String failedToLoadCountry(String country, String error) {
    return '$countryの読み込みに失敗: $error';
  }

  @override
  String get searchCountries => '国を検索...';

  @override
  String loadingCountry(String country) {
    return '$countryを読み込み中...';
  }

  @override
  String get switchingToAudio => '音声に切り替え中...';

  @override
  String get failedToLoad => '読み込みに失敗しました';

  @override
  String get videoNotAvailable => '動画が利用できません';

  @override
  String loadingChannels(int count) {
    return '$countチャンネルを読み込み中...';
  }

  @override
  String errorLoadingChannels(String error) {
    return 'チャンネル読み込みエラー: $error';
  }

  @override
  String get playlistRefreshed => 'プレイリストを更新しました';

  @override
  String get renamePlaylistHint => '新しい名前を入力';

  @override
  String get deletePlaylistConfirmation => 'このプレイリストとすべてのチャンネルが完全に削除されます。';

  @override
  String get copied => 'コピーしました';

  @override
  String get noInternet => 'インターネット接続がありません';

  @override
  String get streamError => 'ストリームエラー';

  @override
  String get tapToRetry => 'タップして再試行';

  @override
  String get audioOnlyDescription => 'バッテリー節約のために音声のみ再生';

  @override
  String get switchToVideoDescription => '動画モードに戻る';

  @override
  String get previousChannel => '前のチャンネル';

  @override
  String get nextChannel => '次のチャンネル';

  @override
  String get closePlayer => 'プレーヤーを閉じる';

  @override
  String get expandPlayer => 'プレーヤーを拡大';

  @override
  String get browse => 'ブラウズ';
}
