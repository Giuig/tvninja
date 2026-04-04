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

  Channel({
    required this.name,
    required this.url,
    this.logo,
    this.group,
    this.playlistId = '',
    this.type = ChannelType.live,
  });

  /// Unique ID based on URL only - stable across app restarts and platforms
  String get uniqueId {
    return url.hashCode.abs().toString();
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'logo': logo,
      'group': group,
      'playlistId': playlistId,
      'type': type.name,
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
    );
  }

  Channel copyWith({
    String? name,
    String? url,
    String? logo,
    String? group,
    String? playlistId,
    ChannelType? type,
  }) {
    return Channel(
      name: name ?? this.name,
      url: url ?? this.url,
      logo: logo ?? this.logo,
      group: group ?? this.group,
      playlistId: playlistId ?? this.playlistId,
      type: type ?? this.type,
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

  List<Channel> get favoriteChannels {
    _cachedFavoriteChannels ??= _allChannels
        .where((c) => _favoriteChannelIds.contains(c.uniqueId))
        .toList();
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

  static const String defaultPlaylistUrl =
      'https://raw.githubusercontent.com/klougithub/TVITALIA-/refs/heads/main/iptvit.m3u';
  static const String defaultPlaylistName = 'Klou IT (DEBUG)';

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
      try {
        final channels = await M3UParser.parse(defaultPlaylistUrl);
        final defaultId = 'default_italian';
        _playlists.add(_withChannelPlaylistId(Playlist(
          id: defaultId,
          name: defaultPlaylistName,
          url: defaultPlaylistUrl,
          channels: channels,
        )));
        _loadError = null;
      } catch (e) {
        debugPrint('Failed to load default playlist: $e');
        _loadError = 'Failed to load default playlist: $e';
        _playlists.add(Playlist(
          id: 'default_italian',
          name: defaultPlaylistName,
          url: defaultPlaylistUrl,
        ));
      }
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

  Future<void> addPlaylist(Playlist playlist) async {
    _playlists.add(playlist);
    _buildAllChannelsList();
    _cachedFavoriteChannels = null;
    await _saveData();
    notifyListeners();
  }

  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    _favoriteChannelIds.removeWhere((fid) => fid.startsWith('${id}_'));
    _buildAllChannelsList();
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
