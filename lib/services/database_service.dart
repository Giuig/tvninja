import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tvninja/config/config.dart';

class DatabaseService {
  static const String _channelsBoxName = 'channels';
  static const String _playlistsBoxName = 'playlists';
  static const String _favoritesBoxName = 'favorites';
  static const String _recentBoxName = 'recent';
  static const String _settingsBoxName = 'settings';

  static late Box<Map> _channelsBox;
  static late Box<Map> _playlistsBox;
  static late Box<List> _favoritesBox;
  static late Box<List> _recentBox;
  static late Box _settingsBox;

  static Future<void> initialize() async {
    await Hive.initFlutter();
    
    _channelsBox = await Hive.openBox<Map>(_channelsBoxName);
    _playlistsBox = await Hive.openBox<Map>(_playlistsBoxName);
    _favoritesBox = await Hive.openBox<List>(_favoritesBoxName);
    _recentBox = await Hive.openBox<List>(_recentBoxName);
    _settingsBox = await Hive.openBox(_settingsBoxName);
  }

  static Future<void> savePlaylists(List<Playlist> playlists) async {
    await _playlistsBox.clear();
    for (final playlist in playlists) {
      await _playlistsBox.put(playlist.id, playlist.toJson());
    }
  }

  static List<Playlist> getPlaylists() {
    return _playlistsBox.values
        .map((json) => Playlist.fromJson(Map<String, dynamic>.from(json)))
        .toList();
  }

  static Future<void> saveChannels(String playlistId, List<Channel> channels) async {
    for (final channel in channels) {
      await _channelsBox.put('${playlistId}_${channel.uniqueId}', channel.toJson());
    }
  }

  static List<Channel> getChannels(String playlistId) {
    return _channelsBox.values
        .where((json) => json['playlistId'] == playlistId)
        .map((json) => Channel.fromJson(Map<String, dynamic>.from(json)))
        .toList();
  }

  static List<Channel> getAllChannels() {
    return _channelsBox.values
        .map((json) => Channel.fromJson(Map<String, dynamic>.from(json)))
        .toList();
  }

  static Future<void> clearChannels(String playlistId) async {
    final keysToDelete = <String>[];
    for (final key in _channelsBox.keys) {
      if (key.toString().startsWith('${playlistId}_')) {
        keysToDelete.add(key.toString());
      }
    }
    await _channelsBox.deleteAll(keysToDelete);
  }

  static Future<void> saveFavorites(Set<String> favoriteIds) async {
    await _favoritesBox.put('favorites', favoriteIds.toList());
  }

  static Set<String> getFavorites() {
    final list = _favoritesBox.get('favorites');
    return list?.cast<String>().toSet() ?? <String>{};
  }

  static Future<void> saveRecent(List<String> recentIds) async {
    await _recentBox.put('recent', recentIds);
  }

  static List<String> getRecent() {
    return _recentBox.get('recent')?.cast<String>() ?? [];
  }

  static Future<void> saveSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  static T? getSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  static Future<void> clearAll() async {
    await _channelsBox.clear();
    await _playlistsBox.clear();
    await _favoritesBox.clear();
    await _recentBox.clear();
  }
}

class DatabaseNotifier extends ChangeNotifier {
  List<Playlist> _playlists = [];
  List<Channel> _allChannels = [];
  Set<String> _favoriteChannelIds = {};
  List<String> _recentlyWatchedIds = [];
  SortOption _sortOption = SortOption.recent;
  int _totalViews = 0;
  bool _isLoading = true;

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<Channel> get allChannels => List.unmodifiable(_allChannels);
  bool get isLoading => _isLoading;
  Set<String> get favoriteChannelIds => Set.from(_favoriteChannelIds);
  SortOption get sortOption => _sortOption;

  List<Channel> get favoriteChannels {
    return _allChannels
        .where((c) => _favoriteChannelIds.contains(c.uniqueId))
        .toList();
  }

  List<Channel> get recentlyWatched {
    return _recentlyWatchedIds
        .map((id) => _allChannels.where((c) => c.uniqueId == id).firstOrNull)
        .whereType<Channel>()
        .toList();
  }

  Future<void> loadData() async {
    _playlists = DatabaseService.getPlaylists();
    _allChannels = DatabaseService.getAllChannels();
    _favoriteChannelIds = DatabaseService.getFavorites();
    _recentlyWatchedIds = DatabaseService.getRecent();
    _sortOption = SortOption.values.firstWhere(
      (e) => e.name == DatabaseService.getSetting<String>('sortOption'),
      orElse: () => SortOption.recent,
    );
    _totalViews = DatabaseService.getSetting<int>('totalViews', defaultValue: 0) ?? 0;
    _isLoading = false;
    notifyListeners();
  }

  void setSortOption(SortOption option) {
    _sortOption = option;
    DatabaseService.saveSetting('sortOption', option.name);
    notifyListeners();
  }

  Future<void> toggleFavorite(Channel channel) async {
    final id = channel.uniqueId;
    if (_favoriteChannelIds.contains(id)) {
      _favoriteChannelIds.remove(id);
    } else {
      _favoriteChannelIds.add(id);
    }
    await DatabaseService.saveFavorites(_favoriteChannelIds);
    notifyListeners();
  }

  Future<void> addPlaylist(Playlist playlist) async {
    _playlists.add(playlist);
    await DatabaseService.savePlaylists(_playlists);
    await DatabaseService.saveChannels(playlist.id, playlist.channels);
    _buildAllChannelsList();
    notifyListeners();
  }

  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await DatabaseService.savePlaylists(_playlists);
    await DatabaseService.clearChannels(id);
    _favoriteChannelIds.removeWhere((fid) => fid.startsWith('${id}_'));
    await DatabaseService.saveFavorites(_favoriteChannelIds);
    _buildAllChannelsList();
    notifyListeners();
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    final index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index != -1) {
      _playlists[index] = playlist;
      await DatabaseService.savePlaylists(_playlists);
      await DatabaseService.saveChannels(playlist.id, playlist.channels);
      _buildAllChannelsList();
      notifyListeners();
    }
  }

  Future<void> refreshPlaylist(String id) async {
    // Implemented in the pages using parsers
  }

  Future<void> incrementViews() async {
    _totalViews++;
    await DatabaseService.saveSetting('totalViews', _totalViews);
    notifyListeners();
  }

  Future<void> addToRecentlyWatched(Channel channel) async {
    _recentlyWatchedIds.remove(channel.uniqueId);
    _recentlyWatchedIds.insert(0, channel.uniqueId);
    if (_recentlyWatchedIds.length > 20) {
      _recentlyWatchedIds = _recentlyWatchedIds.sublist(0, 20);
    }
    await DatabaseService.saveRecent(_recentlyWatchedIds);
    notifyListeners();
  }

  void _buildAllChannelsList() {
    _allChannels = [];
    for (final playlist in _playlists) {
      for (final channel in playlist.channels) {
        _allChannels.add(channel.copyWith(playlistId: playlist.id));
      }
    }
  }

  bool isFavorite(Channel channel) => _favoriteChannelIds.contains(channel.uniqueId);
}
