// lib/config/config.dart

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/services/m3u_parser.dart';

class Channel {
  final String name;
  final String url;
  final String? logo;
  final String? group;
  final String playlistId;
  final ChannelType type;
  final String? userAgent;

  Channel({
    required this.name,
    required this.url,
    this.logo,
    this.group,
    this.playlistId = '',
    this.type = ChannelType.live,
    this.userAgent,
  });

  /// Unique ID based on URL only.
  ///
  /// **Deliberate: a favourite follows the stream, not the playlist entry.**
  /// The same channel present in two playlists is one favourite, and removing
  /// one of those playlists leaves it favourited in the other. Chosen 2026-09-18
  /// over scoping the id to the playlist, which would have been tidier
  /// conceptually but invalidated every saved favourite and needed a migration.
  ///
  /// Consequence to keep in mind: ids outlive the channels they came from, so
  /// anything that deletes channels must prune the favourites that no longer
  /// match — see `removePlaylist`.
  String get uniqueId {
    return url.hashCode.abs().toString();
  }

  /// The group, or null when there is nothing worth showing.
  ///
  /// Playlists do not agree on how to say "no category". iptv-org writes the
  /// literal string `Undefined` — 77 of the 320 channels in its Italy list —
  /// and others use an empty attribute. Printing the word "Undefined" under a
  /// channel name is our choice, not their data, so both collapse to null here.
  String? get displayGroup {
    final g = group?.trim();
    if (g == null || g.isEmpty) return null;
    if (g.toLowerCase() == 'undefined') return null;
    return g;
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'logo': logo,
      'group': group,
      'playlistId': playlistId,
      'type': type.name,
      'userAgent': userAgent,
    };
  }

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      logo: json['logo'],
      group: json['group'],
      playlistId: json['playlistId'] ?? '',
      type: ChannelType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => ChannelType.live,
      ),
      userAgent: json['userAgent'],
    );
  }

  Channel copyWith({
    String? name,
    String? url,
    String? logo,
    String? group,
    String? playlistId,
    ChannelType? type,
    String? userAgent,
  }) {
    return Channel(
      name: name ?? this.name,
      url: url ?? this.url,
      logo: logo ?? this.logo,
      group: group ?? this.group,
      playlistId: playlistId ?? this.playlistId,
      type: type ?? this.type,
      userAgent: userAgent ?? this.userAgent,
    );
  }
}

class Playlist {
  final String id;
  final String name;
  final String url;
  final List<Channel> channels;

  Playlist({
    required this.id,
    required this.name,
    required this.url,
    this.channels = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'url': url,
      'channels': channels.map((c) => c.toJson()).toList(),
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      channels: (json['channels'] as List<dynamic>?)
              ?.map((c) => Channel.fromJson(c))
              .toList() ??
          [],
    );
  }

  Playlist copyWith({
    String? id,
    String? name,
    String? url,
    List<Channel>? channels,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      channels: channels ?? this.channels,
    );
  }
}

enum SortOption {
  name,
  group,
  recent,
}

enum ChannelType {
  live,
  vod,
  series,
}

class AppStatsNotifier extends ChangeNotifier {
  List<Playlist> _playlists = [];
  List<Channel> _allChannels = [];
  Set<String> _favoriteChannelIds = {};
  List<String> _recentlyWatchedIds = [];
  SortOption _sortOption = SortOption.recent;
  int _totalViews = 0;
  bool _isLoading = true;
  String? _loadError;

  List<Channel>? _cachedFavoriteChannels;

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<Channel> get allChannels => List.unmodifiable(_allChannels);
  bool get isLoading => _isLoading;
  String? get loadError => _loadError;
  Set<String> get favoriteChannelIds => Set.from(_favoriteChannelIds);
  SortOption get sortOption => _sortOption;

  List<Channel> get recentlyWatched {
    return _recentlyWatchedIds
        .map((id) => _allChannels.where((c) => c.uniqueId == id).firstOrNull)
        .whereType<Channel>()
        .toList();
  }

  /// Favourited channels, **one entry per stream**.
  ///
  /// The dedupe is the point, not an optimisation. `_allChannels` holds one
  /// `Channel` per playlist *occurrence*, while a favourite is identified by
  /// `uniqueId`, which is derived from the URL — so the same stream present in
  /// two playlists produced two objects sharing one id and the favourites grid
  /// listed it twice. Reported by the owner 2026-09-22.
  ///
  /// That is a consequence of the identity decision taken in 1.5.1 — a
  /// favourite follows the stream, not the playlist entry — which stands. Only
  /// the display was wrong.
  ///
  /// First occurrence wins: playlists are kept in insertion order, so the copy
  /// shown is the one from the playlist added earliest, which is stable across
  /// rebuilds rather than arbitrary.
  List<Channel> get favoriteChannels {
    if (_cachedFavoriteChannels == null) {
      final seen = <String>{};
      _cachedFavoriteChannels = [
        for (final c in _allChannels)
          if (_favoriteChannelIds.contains(c.uniqueId) && seen.add(c.uniqueId))
            c,
      ];
    }
    return _cachedFavoriteChannels!;
  }

  List<Channel> get sortedFavoriteChannels {
    final favorites = favoriteChannels;
    switch (_sortOption) {
      case SortOption.name:
        return List.from(favorites)
          ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case SortOption.group:
        return List.from(favorites)
          ..sort((a, b) {
            final aGroup = a.group ?? '';
            final bGroup = b.group ?? '';
            if (aGroup.isEmpty && bGroup.isEmpty)
              return a.name.compareTo(b.name);
            if (aGroup.isEmpty) return 1;
            if (bGroup.isEmpty) return -1;
            return aGroup.compareTo(bGroup);
          });
      case SortOption.recent:
        return favorites;
    }
  }

  int get totalViews => _totalViews;
  bool isFavorite(Channel channel) =>
      _favoriteChannelIds.contains(channel.uniqueId);

  AppStatsNotifier() {
    _loadData();
  }

  /// Seed playlist for a fresh **debug** install only — see the `kDebugMode`
  /// guard in [_loadData]. A release build never seeds anything.
  ///
  /// These were the *fallback* until 2026-09-22, reached only when fetching a
  /// real playlist failed. They are now the seed outright, at the owner's
  /// request, and the fetch is gone. Purpose-built, long-lived HLS test assets
  /// (Mux's and Apple's reference streams, and the Sintel demo) — deliberately
  /// NOT real TV channels, so the name makes obvious you are looking at a
  /// debug seed and not at content.
  ///
  /// Why this beats fetching iptv-org's country list, which is what used to be
  /// here:
  ///
  /// - **No network at startup.** A debug session cannot be shaped by the
  ///   upstream being slow, or a stream being geo-blocked.
  /// - **Three channels, not ~800.** The country list made every list and
  ///   scroll observation noisy for no benefit.
  /// - **They play.** Repeatedly, during device testing, real channels
  ///   returned "stream unavailable" and cost time proving the app was fine.
  ///
  /// **What this gives up:** a fresh debug install no longer exercises
  /// [M3UParser] end to end, which the old seed did incidentally. That is
  /// covered by `test/m3u_parser_useragent_test.dart` and by adding any real
  /// playlist by hand — but it is a real if small loss, not a free swap.
  static const List<(String, String)> debugSeedStreams = [
    ('Mux Test Stream', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    (
      'Apple BipBop',
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8'
    ),
    (
      'Sintel HLS',
      'https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8'
    ),
  ];

  static const String debugSeedPlaylistName = 'Built-in test streams (DEBUG)';

  Playlist _withChannelPlaylistId(Playlist playlist) {
    return playlist.copyWith(
      channels: playlist.channels
          .map((c) => c.copyWith(playlistId: playlist.id))
          .toList(),
    );
  }

  void _migrateFavorites() {
    final Set<String> migratedFavorites = {};
    for (final id in _favoriteChannelIds) {
      migratedFavorites.add(id);
    }
    _favoriteChannelIds = migratedFavorites;
  }

  Future<void> _loadData() async {
    SharedPreferences preferences = await SharedPreferences.getInstance();

    _totalViews = preferences.getInt('totalViews') ?? 0;

    List<String>? favoritesJson = preferences.getStringList('favorites');
    _favoriteChannelIds = favoritesJson?.toSet() ?? {};

    List<String>? recentlyJson = preferences.getStringList('recentlyWatched');
    _recentlyWatchedIds = recentlyJson ?? [];

    String? sortStr = preferences.getString('sortOption');
    _sortOption = SortOption.values.firstWhere(
      (e) => e.name == sortStr,
      orElse: () => SortOption.recent,
    );

    List<String>? playlistsJson = preferences.getStringList('playlists');
    _playlists = playlistsJson?.map((json) {
          Map<String, dynamic> data = jsonDecode(json);
          return Playlist.fromJson(data);
        }).toList() ??
        [];

    _buildAllChannelsList();

    _migrateFavorites();

    if (_playlists.isEmpty && kDebugMode) {
      // No fetch, no parse, no failure path — see [debugSeedStreams].
      _playlists.add(_withChannelPlaylistId(Playlist(
        id: 'debug_seed_streams',
        name: debugSeedPlaylistName,
        url: '',
        channels: [
          for (final (name, url) in debugSeedStreams)
            Channel(name: name, url: url, group: 'Test'),
        ],
      )));
    }

    _buildAllChannelsList();
    _isLoading = false;
    notifyListeners();
  }

  void _buildAllChannelsList() {
    _allChannels = [];
    for (var playlist in _playlists) {
      for (var channel in playlist.channels) {
        _allChannels.add(channel.copyWith(playlistId: playlist.id));
      }
    }
  }

  Future<void> _saveData() async {
    SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setInt('totalViews', _totalViews);
    await preferences.setStringList('favorites', _favoriteChannelIds.toList());
    await preferences.setStringList('recentlyWatched', _recentlyWatchedIds);
    await preferences.setString('sortOption', _sortOption.name);

    List<String> playlistsJson =
        _playlists.map((p) => jsonEncode(p.toJson())).toList();
    await preferences.setStringList('playlists', playlistsJson);
  }

  void setSortOption(SortOption option) {
    _sortOption = option;
    _saveData();
    notifyListeners();
  }

  Future<void> toggleFavorite(Channel channel) async {
    final id = channel.uniqueId;
    if (_favoriteChannelIds.contains(id)) {
      _favoriteChannelIds.remove(id);
    } else {
      _favoriteChannelIds.add(id);
    }
    _cachedFavoriteChannels = null;
    await _saveData();
    notifyListeners();
  }

  /// Normalised form of a playlist URL, for duplicate detection only.
  ///
  /// Trim, lowercase, and drop a single trailing slash — nothing more.
  /// Specifically **not** stripping the query string: Xtream URLs carry the
  /// username and password there, so two entries differing only in query are
  /// genuinely different playlists.
  static String normalisePlaylistUrl(String url) {
    var u = url.trim().toLowerCase();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  /// Whether a playlist with the same (normalised) URL is already added.
  bool hasPlaylistWithUrl(String url) {
    if (url.trim().isEmpty) return false;
    final target = normalisePlaylistUrl(url);
    return _playlists.any((p) => normalisePlaylistUrl(p.url) == target);
  }

  /// Adds [playlist], unless one with the same URL is already present.
  ///
  /// Returns false when it was rejected as a duplicate, so the caller can say
  /// so. Deliberately **not** throwing: a duplicate is a normal thing for a
  /// user to attempt, not an error condition.
  ///
  /// Matched on URL rather than name, on purpose. Two different sources can
  /// legitimately carry the same name, while the same URL twice is never
  /// intentional — and it used to duplicate every one of that playlist's
  /// channels into `_allChannels`, which is what feeds the favourites grid.
  /// Owner report, 2026-09-22: "i cna add same playlist twice with the same
  /// name".
  ///
  /// An empty URL is never treated as a duplicate — the debug seed uses one,
  /// and so would any future playlist that is not fetched from anywhere.
  Future<bool> addPlaylist(Playlist playlist) async {
    if (hasPlaylistWithUrl(playlist.url)) return false;
    _playlists.add(playlist);
    _buildAllChannelsList();
    _cachedFavoriteChannels = null;
    await _saveData();
    notifyListeners();
    return true;
  }

  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    _buildAllChannelsList();
    // Prune favourites whose channel no longer exists anywhere.
    //
    // This replaces a `removeWhere((fid) => fid.startsWith('${id}_'))` that
    // could never match: uniqueId is `url.hashCode`, a bare digit string, while
    // that prefix belongs to the Hive box keys. It looked like cleanup and did
    // nothing, so ids accumulated forever and re-adding a playlist silently
    // resurrected old favourites.
    //
    // Pruned here rather than on load: this is the one moment we know channels
    // were deliberately removed. Doing it at load time would risk wiping
    // favourites whenever a playlist happened to be missing.
    final live = _allChannels.map((c) => c.uniqueId).toSet();
    _favoriteChannelIds.removeWhere((fid) => !live.contains(fid));
    _cachedFavoriteChannels = null;
    await _saveData();
    notifyListeners();
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    int index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index != -1) {
      _playlists[index] = playlist;
      _buildAllChannelsList();
      _cachedFavoriteChannels = null;
      await _saveData();
      notifyListeners();
    }
  }

  Future<void> renamePlaylist(String id, String newName) async {
    int index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1) {
      _playlists[index] = _playlists[index].copyWith(name: newName);
      await _saveData();
      notifyListeners();
    }
  }

  Future<void> refreshPlaylist(String id) async {
    int index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1) {
      final playlist = _playlists[index];
      try {
        final channels = await M3UParser.parse(playlist.url);
        _playlists[index] =
            _withChannelPlaylistId(playlist.copyWith(channels: channels));
        _buildAllChannelsList();
        _cachedFavoriteChannels = null;
        await _saveData();
        notifyListeners();
      } catch (e) {
        // Failed to refresh, keep existing
      }
    }
  }

  Future<void> incrementViews() async {
    _totalViews++;
    await _saveData();
    notifyListeners();
  }

  Future<void> addToRecentlyWatched(Channel channel) async {
    _recentlyWatchedIds.remove(channel.uniqueId);
    _recentlyWatchedIds.insert(0, channel.uniqueId);
    if (_recentlyWatchedIds.length > 20) {
      _recentlyWatchedIds = _recentlyWatchedIds.sublist(0, 20);
    }
    await _saveData();
    notifyListeners();
  }

  Future<void> globalResetData() async {
    _playlists = [];
    _allChannels = [];
    _favoriteChannelIds = {};
    _recentlyWatchedIds = [];
    _totalViews = 0;
    _cachedFavoriteChannels = null;
    await _saveData();
    notifyListeners();
  }
}

final AppStatsNotifier appStatsNotifier = AppStatsNotifier();

Future<void> initializeGlobals() async {}
