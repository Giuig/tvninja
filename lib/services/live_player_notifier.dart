import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/services/mpv_options.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/pip_service.dart';

class LivePlayerNotifier extends ChangeNotifier {
  static final LivePlayerNotifier _instance = LivePlayerNotifier._();
  factory LivePlayerNotifier() => _instance;
  LivePlayerNotifier._();

  Player? _player;
  VideoController? _videoController;
  Channel? _currentChannel;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _showPlayer = false;
  bool _isExpanded = false;
  bool _isAudioOnly = false;
  double _volume = 100.0;
  bool _hasModalOverlay = false;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;

  Channel? get currentChannel => _currentChannel;
  bool get isPlaying => _isPlaying;
  set isPlaying(bool value) {
    if (_isPlaying == value) return;
    _isPlaying = value;
    notifyListeners();
  }

  bool get isBuffering => _isBuffering;
  bool get isInitialized => _isInitialized;
  bool get hasError => _hasError;
  String get errorMessage => _errorMessage;
  bool get showPlayer => _showPlayer;
  bool get isExpanded => _isExpanded;
  bool get isAudioOnly => _isAudioOnly;
  double get volume => _volume;
  bool get hasActivePlayer => _currentChannel != null;
  bool get hasModalOverlay => _hasModalOverlay;

  void setModalOverlay(bool value) {
    if (_hasModalOverlay == value) return;
    _hasModalOverlay = value;
    notifyListeners();
  }

  Player? get player => _player;
  VideoController? get videoController => _videoController;

  StreamSubscription<PlaybackControl>? _controlSubscription;
  StreamSubscription<bool>? _audioBufferingSubscription;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  bool _isSwitchingToAudio = false;
  bool _hasStartedAudioBuffering =
      false; // Track if we've actually started buffering
  bool get isSwitchingToAudio => _isSwitchingToAudio;

  Future<void> toggleAudioOnly() async {
    if (_currentChannel == null) return;

    _isAudioOnly = !_isAudioOnly;

    if (_isAudioOnly) {
      // Entering audio-only mode — disable PiP so Home doesn't trigger it
      PipService.setFullscreenVideoMode(false);

      _isSwitchingToAudio = true;
      _isBuffering = true;
      _hasStartedAudioBuffering = false; // Reset tracking flag
      notifyListeners();

      // Stop video player to save battery
      if (!kIsWeb) {
        await _player?.stop();
      }
      _isInitialized = false;

      // Start background audio service with notification
      await NativeAudioService.initialize();

      _setupAudioSubscriptions();

      await NativeAudioService.play(
        url: _currentChannel!.url,
        title: _currentChannel!.name,
        logo: _currentChannel!.logo,
      );

      // Fallback: end the "switching" transition after 3 s even if stream events
      // haven't fired. Do NOT clear _isBuffering here — let the actual buffering
      // and playing stream events control it so the spinner stays visible.
      Future.delayed(const Duration(seconds: 3), () {
        if (_isSwitchingToAudio && _isAudioOnly) {
          _isSwitchingToAudio = false;
          notifyListeners();
        }
      });
    } else {
      // Exiting audio-only mode, return to video
      // Re-enable PiP if we're in fullscreen/expanded mode
      if (_isExpanded) {
        PipService.setFullscreenVideoMode(true);
      }
      await NativeAudioService.stop();
      _audioBufferingSubscription?.cancel();
      _audioBufferingSubscription = null;
      _playbackStateSubscription?.cancel();
      _playbackStateSubscription = null;
      _controlSubscription?.cancel();
      _controlSubscription = null;

      // Restart video player
      await initialize();
      if (!kIsWeb && _currentChannel != null) {
        _isBuffering = true;
        notifyListeners();

        try {
          await _player!.open(Media(_currentChannel!.url), play: true);
          _isInitialized = true;
          _isBuffering = false;
          notifyListeners();
        } catch (e) {
          _hasError = true;
          _errorMessage = e.toString();
          _isBuffering = false;
          notifyListeners();
        }
      }
    }
  }

  void _setupAudioSubscriptions() {
    _audioBufferingSubscription?.cancel();
    _audioBufferingSubscription =
        NativeAudioService.bufferingStream.listen((buffering) {
      _isBuffering = buffering;
      if (buffering) {
        _hasStartedAudioBuffering = true;
        notifyListeners();
      } else if (_hasStartedAudioBuffering && _isAudioOnly) {
        _isSwitchingToAudio = false;
        _isPlaying = true;
        _hasStartedAudioBuffering = false;
        notifyListeners();
      }
    });

    _playbackStateSubscription?.cancel();
    _playbackStateSubscription =
        NativeAudioService.playbackStateStream.listen((state) {
      if (state.isPlaying && _isAudioOnly) {
        _isSwitchingToAudio = false;
        _isPlaying = true;
        _isBuffering = false;
        _hasStartedAudioBuffering = false;
        notifyListeners();
      }
    });

    _controlSubscription?.cancel();
    _controlSubscription = NativeAudioService.controlStream.listen((control) {
      switch (control) {
        case PlaybackControl.play:
          NativeAudioService.resume();
          _isPlaying = true;
          notifyListeners();
          break;
        case PlaybackControl.pause:
          NativeAudioService.pause();
          _isPlaying = false;
          notifyListeners();
          break;
        case PlaybackControl.stop:
          stop();
          break;
      }
    });
  }

  void setVolume(double volume) {
    if (_volume == volume) return;
    _volume = volume;
    if (!_isAudioOnly) {
      _player?.setVolume(volume);
    }
    notifyListeners();
  }

  Future<void> initialize() async {
    if (kIsWeb) {
      debugPrint('[Player] initialize() - Web mode, skipping');
      return;
    }
    if (_player != null) {
      debugPrint('[Player] initialize() - Player already exists');
      return;
    }

    debugPrint('[Player] initialize() - Creating new Player');
    _player = Player();
    _videoController = VideoController(_player!);
    debugPrint('[Player] initialize() - Player and VideoController created');
    await applyLiveStreamMpvOptions(_player!);

    _playingSubscription = _player!.stream.playing.listen((playing) {
      if (_isPlaying == playing) return;
      _isPlaying = playing;
      notifyListeners();
    });

    _bufferingSubscription = _player!.stream.buffering.listen((buffering) {
      if (_isBuffering == buffering) return;
      _isBuffering = buffering;
      notifyListeners();
    });
  }

  Future<void> playChannel(Channel channel) async {
    debugPrint('[Player] playChannel called: ${channel.name} - ${channel.url}');
    final bool wasAudioOnly = _isAudioOnly;

    // Cancel existing audio subscriptions
    _audioBufferingSubscription?.cancel();
    _audioBufferingSubscription = null;
    _playbackStateSubscription?.cancel();
    _playbackStateSubscription = null;
    _controlSubscription?.cancel();
    _controlSubscription = null;

    // Stop any existing audio-only mode
    if (wasAudioOnly) {
      await NativeAudioService.stop();
    }

    await initialize();

    _currentChannel = channel;
    _hasError = false;
    _errorMessage = '';
    _showPlayer = true;
    _isExpanded = false;
    _isPlaying = true;
    _isInitialized = false;
    _isBuffering = true;
    _hasStartedAudioBuffering = false;
    // Keep the audio-only mode as it was before switching
    _isAudioOnly = wasAudioOnly;
    notifyListeners();

    if (kIsWeb) {
      debugPrint('[Player] Web mode - using WebVideoPlayerWidget');
      // Web will use iframe/video element via WebVideoPlayerWidget
      return;
    }

    if (wasAudioOnly) {
      debugPrint('[Player] Audio-only mode');
      // Start audio-only mode for the new channel
      _isSwitchingToAudio = true;
      notifyListeners();

      await NativeAudioService.initialize();

      _setupAudioSubscriptions();

      await NativeAudioService.play(
        url: channel.url,
        title: channel.name,
        logo: channel.logo,
      );

      // Fallback: end the "switching" transition after 3 s even if stream events
      // haven't fired. Do NOT clear _isBuffering — let actual stream events do it.
      Future.delayed(const Duration(seconds: 3), () {
        if (_isSwitchingToAudio && _isAudioOnly) {
          _isSwitchingToAudio = false;
          notifyListeners();
        }
      });
    } else {
      // Start video mode
      debugPrint('[Player] Video mode - opening with media_kit');
      try {
        debugPrint('[Player] Player is null: ${_player == null}');
        debugPrint('[Player] Calling player.open()...');
        await _player!.open(Media(channel.url), play: true);
        debugPrint('[Player] Media opened successfully');
        _isInitialized = true;
        _isBuffering = false;
        notifyListeners();
      } catch (e, stackTrace) {
        debugPrint('[Player] ERROR: $e');
        debugPrint('[Player] Stack trace: $stackTrace');
        _hasError = true;
        _errorMessage = e.toString();
        _isBuffering = false;
        notifyListeners();
      }
    }
  }

  Future<void> play() async {
    if (kIsWeb) {
      _isPlaying = true;
      notifyListeners();
      return;
    }
    if (_isAudioOnly) {
      await NativeAudioService.resume();
      _isPlaying = true;
      notifyListeners();
    } else {
      await _player?.play();
    }
  }

  Future<void> pause() async {
    if (kIsWeb) {
      _isPlaying = false;
      notifyListeners();
      return;
    }
    if (_isAudioOnly) {
      await NativeAudioService.pause();
      _isPlaying = false;
      notifyListeners();
    } else {
      await _player?.pause();
    }
  }

  Future<void> togglePlayPause() async {
    if (_isAudioOnly) {
      if (_isPlaying) {
        await NativeAudioService.pause();
        _isPlaying = false;
      } else {
        await NativeAudioService.resume();
        _isPlaying = true;
      }
      notifyListeners();
    } else {
      if (_isPlaying) {
        await _player?.pause();
      } else {
        await _player?.play();
      }
    }
  }

  Future<void> stop() async {
    // Cancel control subscription first to avoid receiving stop event from service
    _controlSubscription?.cancel();
    _controlSubscription = null;
    _audioBufferingSubscription?.cancel();
    _audioBufferingSubscription = null;
    _playbackStateSubscription?.cancel();
    _playbackStateSubscription = null;

    // Stop native audio service
    await NativeAudioService.stop();

    if (!kIsWeb) {
      await _player?.stop();
    }
    _showPlayer = false;
    _currentChannel = null;
    _isInitialized = false;
    _isPlaying = false;
    _isAudioOnly = false;
    _isSwitchingToAudio = false;
    _isBuffering = false;
    _hasStartedAudioBuffering = false;
    PipService.setFullscreenVideoMode(false);
    notifyListeners();
  }

  Future<void> minimize() async {
    _isExpanded = false;
    PipService.setFullscreenVideoMode(false);
    notifyListeners();
  }

  Future<void> expand() async {
    _isExpanded = true;
    PipService.setFullscreenVideoMode(true);
    notifyListeners();
  }

  void hidePlayer() {
    _showPlayer = false;
    notifyListeners();
  }

  void showPlayerView() {
    _showPlayer = true;
    notifyListeners();
  }

  // Web PiP - callback that widget sets to request PiP
  VoidCallback? _onRequestPiP;
  void setPiPCallback(VoidCallback callback) => _onRequestPiP = callback;

  void requestWebPiP() {
    if (!kIsWeb) return;
    _onRequestPiP?.call();
  }

  @override
  void dispose() {
    _playingSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _controlSubscription?.cancel();
    _audioBufferingSubscription?.cancel();
    _playbackStateSubscription?.cancel();
    _player?.dispose();
    super.dispose();
  }
}
