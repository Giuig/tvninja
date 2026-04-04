import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:tvninja/config/config.dart';

enum XtreamStreamType { live, vod, series }

class XtreamChannelInfo {
  final int? streamId;
  final String name;
  final String? streamIcon;
  final int? categoryId;
  final String? categoryName;
  final XtreamStreamType streamType;
  final String? containerExtension;
  final int? seriesId;
  final int? duration;
  final String? plot;
  final String? guard;
  final List<XtreamEpisode>? episodes;

  XtreamChannelInfo({
    this.streamId,
    required this.name,
    this.streamIcon,
    this.categoryId,
    this.categoryName,
    this.streamType = XtreamStreamType.live,
    this.containerExtension,
    this.seriesId,
    this.duration,
    this.plot,
    this.guard,
    this.episodes,
  });

  Channel toChannel(String baseUrl, String username, String password, String playlistUrl) {
    String url;
    
    switch (streamType) {
      case XtreamStreamType.live:
        final ext = containerExtension ?? 'm3u8';
        url = '$baseUrl/live/$username/$password/$streamId.$ext';
        break;
      case XtreamStreamType.vod:
        url = '$baseUrl/movie/$username/$password/$streamId.$containerExtension';
        break;
      case XtreamStreamType.series:
        url = '$baseUrl/series/$username/$password/$seriesId.json';
        break;
    }

    return Channel(
      name: name,
      url: url,
      logo: streamIcon,
      group: categoryName,
      playlistId: playlistUrl,
      type: streamType == XtreamStreamType.live 
          ? ChannelType.live 
          : (streamType == XtreamStreamType.vod ? ChannelType.vod : ChannelType.series),
    );
  }
}

class XtreamEpisode {
  final int id;
  final int episodeNum;
  final String title;
  final String? containerExtension;
  final String? info;
  final String? guard;

  XtreamEpisode({
    required this.id,
    required this.episodeNum,
    required this.title,
    this.containerExtension,
    this.info,
    this.guard,
  });
}

class XtreamCredentials {
  final String url;
  final String username;
  final String password;

  XtreamCredentials({
    required this.url,
    required this.username,
    required this.password,
  });
}

class XtreamInfo {
  final String? serverProtocol;
  final int? port;
  final int? httpsPort;
  final List<String> allowedOutputFormats;
  final int? maxConnections;

  XtreamInfo({
    this.serverProtocol,
    this.port,
    this.httpsPort,
    this.allowedOutputFormats = const ['m3u8', 'ts'],
    this.maxConnections,
  });
}

class XtreamParser {
  static Stream<XtreamChannelInfo> parseStream(XtreamCredentials creds, {XtreamStreamType? filter}) async* {
    final baseUrl = creds.url.replaceAll(RegExp(r'/$'), '');
    
    final streams = await Future.wait([
      if (filter == null || filter == XtreamStreamType.live)
        _fetchLiveStreams(creds, baseUrl),
      if (filter == null || filter == XtreamStreamType.vod)
        _fetchVodStreams(creds, baseUrl),
      if (filter == null || filter == XtreamStreamType.series)
        _fetchSeriesStreams(creds, baseUrl),
    ]);

    for (final streamList in streams) {
      yield* Stream.fromIterable(streamList);
    }
  }

  static Future<List<XtreamChannelInfo>> _fetchLiveStreams(XtreamCredentials creds, String baseUrl) async {
    try {
      final apiUrl = '$baseUrl/player_api.php?username=${creds.username}&password=${creds.password}&action=get_live_streams';
      final response = await http.get(Uri.parse(apiUrl));
      
      if (response.statusCode != 200) return [];
      
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => XtreamChannelInfo(
        streamId: item['stream_id'],
        name: item['name'] ?? 'Unknown',
        streamIcon: item['stream_icon'],
        categoryId: item['category_id'],
        streamType: XtreamStreamType.live,
        containerExtension: 'm3u8',
      )).toList();
    } catch (e) {
      return [];
    }
  }

  static Future<List<XtreamChannelInfo>> _fetchVodStreams(XtreamCredentials creds, String baseUrl) async {
    try {
      final apiUrl = '$baseUrl/player_api.php?username=${creds.username}&password=${creds.password}&action=get_vod_streams';
      final response = await http.get(Uri.parse(apiUrl));
      
      if (response.statusCode != 200) return [];
      
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => XtreamChannelInfo(
        streamId: item['stream_id'],
        name: item['name'] ?? 'Unknown',
        streamIcon: item['stream_icon'],
        categoryId: item['category_id'],
        streamType: XtreamStreamType.vod,
        containerExtension: 'mp4',
        duration: item['duration'],
        plot: item['plot'],
      )).toList();
    } catch (e) {
      return [];
    }
  }

  static Future<List<XtreamChannelInfo>> _fetchSeriesStreams(XtreamCredentials creds, String baseUrl) async {
    try {
      final apiUrl = '$baseUrl/player_api.php?username=${creds.username}&password=${creds.password}&action=get_series';
      final response = await http.get(Uri.parse(apiUrl));
      
      if (response.statusCode != 200) return [];
      
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => XtreamChannelInfo(
        seriesId: item['id'],
        name: item['name'] ?? 'Unknown',
        streamIcon: item['cover'],
        categoryId: item['category_id'],
        streamType: XtreamStreamType.series,
        plot: item['plot'],
        guard: item['guard'],
      )).toList();
    } catch (e) {
      return [];
    }
  }

  static Future<XtreamInfo?> getServerInfo(XtreamCredentials creds) async {
    try {
      final baseUrl = creds.url.replaceAll(RegExp(r'/$'), '');
      final apiUrl = '$baseUrl/player_api.php?username=${creds.username}&password=${creds.password}';
      final response = await http.get(Uri.parse(apiUrl));
      
      if (response.statusCode != 200) return null;
      
      final Map<String, dynamic> data = jsonDecode(response.body);
      final serverInfo = data['server_info'] ?? {};
      final userInfo = data['user_info'] ?? {};
      
      return XtreamInfo(
        serverProtocol: serverInfo['server_protocol'],
        port: serverInfo['port'],
        httpsPort: serverInfo['https_port'],
        allowedOutputFormats: (serverInfo['allowed_output_formats'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ?? ['m3u8', 'ts'],
        maxConnections: userInfo['max_connections'],
      );
    } catch (e) {
      return null;
    }
  }

  static Future<List<XtreamChannelInfo>> parse(String url, String username, String password, {XtreamStreamType? filter}) async {
    final creds = XtreamCredentials(url: url, username: username, password: password);
    final channels = <XtreamChannelInfo>[];
    
    await for (final channel in parseStream(creds, filter: filter)) {
      channels.add(channel);
    }
    
    return channels;
  }

  static XtreamCredentials? parseCredentials(String inputUrl) {
    try {
      final uri = Uri.parse(inputUrl);
      
      final username = uri.queryParameters['username'];
      final password = uri.queryParameters['password'];
      
      if (username != null && password != null) {
        var baseUrl = inputUrl;
        if (baseUrl.contains('?')) {
          baseUrl = baseUrl.substring(0, baseUrl.indexOf('?'));
        }
        baseUrl = baseUrl.replaceAll('/player_api.php', '').replaceAll('/get.php', '');
        
        return XtreamCredentials(
          url: baseUrl,
          username: username,
          password: password,
        );
      }
    } catch (e) {
      // Ignore
    }
    return null;
  }
}
