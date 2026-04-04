import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class WebVideoPlayerWidget extends StatefulWidget {
  final String url;
  final String channelName;
  final String? channelLogo;
  final bool autoPlay;
  final void Function(bool isPlaying)? onPlayingChanged;
  final void Function(Duration position)? onPositionChanged;
  final void Function(String? error)? onError;
  final void Function()? onCompleted;
  final VoidCallback? onClose;
  final VoidCallback? onEnterPiP;

  const WebVideoPlayerWidget({
    super.key,
    required this.url,
    this.channelName = '',
    this.channelLogo,
    this.autoPlay = true,
    this.onPlayingChanged,
    this.onPositionChanged,
    this.onError,
    this.onCompleted,
    this.onClose,
    this.onEnterPiP,
  });

  @override
  State<WebVideoPlayerWidget> createState() => WebVideoPlayerWidgetState();
}

class WebVideoPlayerWidgetState extends State<WebVideoPlayerWidget> {
  bool _isInitialized = false;
  bool _hasError = false;
  bool _isPlaying = false;
  String _errorMessage = '';
  String? _playerId;
  web.HTMLVideoElement? _videoElement;
  bool _isPiPSupported = false;

  @override
  void initState() {
    super.initState();
    _isPiPSupported = _checkPiPSupport();
    _initializePlayer();
  }

  @override
  void didUpdateWidget(WebVideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cleanup();
      _initializePlayer();
    }
  }

  bool _checkPiPSupport() {
    return web.document.pictureInPictureEnabled;
  }

  void _cleanup() {
    _videoElement?.pause();
    _videoElement = null;
    _isInitialized = false;
    _hasError = false;
    _isPlaying = false;
    _errorMessage = '';
  }

  String _escapeJs(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
  }

  void _initializePlayer() {
    debugPrint('[WebVideo] Initializing player for URL: ${widget.url}');
    _playerId = 'player_${DateTime.now().millisecondsSinceEpoch}';

    // Build list of URLs to try: HTTPS first, then proxies, then direct
    final originalUrl = widget.url;
    final List<String> urlsToTry = [];

    if (originalUrl.startsWith('http://')) {
      // Try HTTPS version first (if server supports it)
      final httpsUrl = originalUrl.replaceFirst('http://', 'https://');
      urlsToTry.add(httpsUrl);
      // Then proxy fallbacks
      urlsToTry
          .add('https://corsproxy.io/?${Uri.encodeComponent(originalUrl)}');
      urlsToTry.add(
          'https://api.allorigins.win/raw?url=${Uri.encodeComponent(originalUrl)}');
      urlsToTry.add(originalUrl); // Last resort: direct HTTP
    } else {
      urlsToTry.add(originalUrl);
    }

    // Create JSON array of URLs for JavaScript
    final urlsJson = urlsToTry.map((u) => '"${_escapeJs(u)}"').join(',');
    debugPrint('[WebVideo] Will try ${urlsToTry.length} URLs: $urlsToTry');
    final escapedName = _escapeJs(widget.channelName);
    final escapedLogo =
        widget.channelLogo != null ? _escapeJs(widget.channelLogo!) : '';

    // Create HTML with direct video element (not iframe)
    final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.7"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; background: black; overflow: hidden; }
    video { width: 100%; height: 100%; object-fit: contain; display: block; }
    #unmute-btn {
      position: absolute;
      bottom: 60px;
      left: 50%;
      transform: translateX(-50%);
      padding: 8px 16px;
      background: rgba(0,0,0,0.7);
      border: 1px solid rgba(255,255,255,0.3);
      border-radius: 20px;
      color: white;
      font-size: 14px;
      cursor: pointer;
      z-index: 100;
      display: none;
    }
    #unmute-btn:hover { background: rgba(0,0,0,0.9); }
  </style>
</head>
<body>
  <video id="video" controls playsinline></video>
  <button id="unmute-btn" onclick="unmute()">&#x1F508; Tap for sound</button>
  <script>
    const video = document.getElementById('video');
    const unmuteBtn = document.getElementById('unmute-btn');
    const urlsToTry = [$urlsJson];
    var currentUrlIndex = 0;
    var userHasUnmuted = localStorage.getItem('tvninja_unmuted') === 'true';
    var isMuted = false;
    var hls = null;
    
    function log(msg) {
      console.log('[WebVideo] ' + msg);
    }
    
    video.autoplay = true;
    
    function unmute() {
      video.muted = false;
      userHasUnmuted = true;
      localStorage.setItem('tvninja_unmuted', 'true');
      unmuteBtn.style.display = 'none';
      isMuted = false;
    }
    
    function startPlayback() {
      // If user previously unmuted, try with sound first
      if (userHasUnmuted) {
        video.muted = false;
        video.play().then(function() {
          unmuteBtn.style.display = 'none';
          window.parent.postMessage('playing:true', '*');
        }).catch(function(e) {
          // Autoplay with sound blocked, try muted
          video.muted = true;
          video.play().then(function() {
            isMuted = true;
            unmuteBtn.style.display = 'block';
            window.parent.postMessage('playing:true', '*');
          }).catch(function(e2) {
            console.log('Autoplay completely blocked');
          });
        });
      } else {
        // First time - try with sound
        video.muted = false;
        video.play().then(function() {
          unmuteBtn.style.display = 'none';
          window.parent.postMessage('playing:true', '*');
        }).catch(function(e) {
          // Sound blocked, fallback to muted
          video.muted = true;
          isMuted = true;
          video.play().then(function() {
            unmuteBtn.style.display = 'block';
            window.parent.postMessage('playing:true', '*');
          }).catch(function(e2) {
            console.log('Autoplay completely blocked');
          });
        });
      }
    }
    
    function startPositionUpdates() {
      video.addEventListener('timeupdate', function() {
        window.parent.postMessage('position:' + video.currentTime, '*');
      });
    }
    
    video.addEventListener('playing', function() {
      window.parent.postMessage('playing:true', '*');
    });
    
    video.addEventListener('pause', function() {
      window.parent.postMessage('playing:false', '*');
    });
    
    video.addEventListener('waiting', function() {
      window.parent.postMessage('buffering:true', '*');
    });
    
    video.addEventListener('ended', function() {
      window.parent.postMessage('completed', '*');
    });
    
    video.addEventListener('error', function() {
      window.parent.postMessage('error:stream_error', '*');
    });
    
    function tryNextUrl() {
      currentUrlIndex++;
      if (currentUrlIndex < urlsToTry.length) {
        log('Trying source ' + (currentUrlIndex + 1) + '/' + urlsToTry.length + '...');
        loadStream(urlsToTry[currentUrlIndex]);
      } else {
        log('All sources failed - try Android app');
        window.parent.postMessage('error:all_sources_failed', '*');
      }
    }
    
    function loadStream(url) {
      log('Loading: ' + url.substring(0, 50) + '...');
      console.log('[WebVideo] Trying URL ' + (currentUrlIndex + 1) + ': ' + url);
      
      if (hls) {
        hls.destroy();
        hls = null;
      }
      
      if (typeof Hls !== 'undefined' && Hls.isSupported()) {
        var networkRecoveries = 0;
        var mediaRecoveries = 0;

        hls = new Hls({
          enableWorker: true,
          lowLatencyMode: false,
          backBufferLength: 30,
          maxBufferLength: 10,
          maxMaxBufferLength: 30,
          maxBufferSize: 60 * 1000 * 1000,
          fragLoadingMaxRetry: 6,
          fragLoadingRetryDelay: 1000,
          fragLoadingMaxRetryTimeout: 32000,
          manifestLoadingMaxRetry: 4,
          manifestLoadingRetryDelay: 1000,
          levelLoadingMaxRetry: 4,
          startFragPrefetch: true,
          liveDurationInfinity: true,
          liveSyncDurationCount: 3,
        });

        hls.loadSource(url);
        hls.attachMedia(video);

        hls.on(Hls.Events.MANIFEST_PARSED, function() {
          log('Playing');
          networkRecoveries = 0;
          mediaRecoveries = 0;
          startPlayback();
          startPositionUpdates();
        });

        hls.on(Hls.Events.ERROR, function(event, data) {
          console.log('[WebVideo] HLS error:', data.type, data.fatal, data.details);
          if (!data.fatal) {
            // Non-fatal stall: nudge the loader to restart
            if (data.details === Hls.ErrorDetails.BUFFER_STALLED_ERROR ||
                data.details === Hls.ErrorDetails.BUFFER_SEEK_OVER_HOLE) {
              hls.startLoad();
            }
            return;
          }
          if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
            if (networkRecoveries < 3) {
              networkRecoveries++;
              var delay = networkRecoveries * 2000;
              console.log('[WebVideo] Network error, retrying in ' + delay + 'ms (' + networkRecoveries + '/3)');
              setTimeout(function() { if (hls) hls.startLoad(); }, delay);
            } else {
              networkRecoveries = 0;
              log('Network error, trying next source...');
              tryNextUrl();
            }
          } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
            if (mediaRecoveries < 2) {
              mediaRecoveries++;
              console.log('[WebVideo] Media error, recovering (' + mediaRecoveries + '/2)');
              hls.recoverMediaError();
            } else {
              mediaRecoveries = 0;
              tryNextUrl();
            }
          } else {
            tryNextUrl();
          }
        });
      } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
        video.src = url;
        video.addEventListener('loadedmetadata', function() {
          log('Playing (native HLS)');
          startPlayback();
          startPositionUpdates();
        }, { once: true });
        video.addEventListener('error', function() {
          log('Error, trying next...');
          tryNextUrl();
        }, { once: true });
      } else {
        video.src = url;
        video.addEventListener('loadedmetadata', function() {
          log('Playing');
          startPlayback();
          startPositionUpdates();
        }, { once: true });
        video.addEventListener('error', function() {
          log('Error, trying next...');
          tryNextUrl();
        }, { once: true });
      }
    }
    
    // Start with first URL
    loadStream(urlsToTry[0]);
    
    // Expose requestPiP method
    window.requestVideoPiP = function() {
      if (document.pictureInPictureElement) {
        document.exitPictureInPicture();
      } else if (document.pictureInPictureEnabled && video) {
        return video.requestPictureInPicture();
      }
      return Promise.reject('PiP not supported');
    };
    
    // Listen for messages from parent (PiP, play, pause)
    window.addEventListener('message', function(event) {
      const msg = event.data;
      if (msg === 'requestPiP') {
        window.requestVideoPiP();
      } else if (msg === 'play') {
        video.play();
      } else if (msg === 'pause') {
        video.pause();
        window.parent.postMessage('playing:false', '*');
      }
    });
  </script>
</body>
</html>
''';

    ui_web.platformViewRegistry.registerViewFactory(
      _playerId!,
      (int viewId) {
        debugPrint('[WebVideo] Creating iframe for viewId: $viewId');
        final iframe =
            web.document.createElement('iframe') as web.HTMLIFrameElement;
        iframe.style.border = 'none';
        iframe.style.width = '100%';
        iframe.style.height = '100%';
        iframe.style.backgroundColor = 'black';
        iframe.setAttribute('srcdoc', htmlContent);
        return iframe;
      },
    );

    debugPrint('[WebVideo] Registered view factory: $_playerId');
    // Listen for messages from iframe
    web.window.onMessage.listen((event) {
      final message = event.data.toString();
      _handleMessage(message);
    });

    setState(() {
      _isInitialized = true;
    });
  }

  void _handleMessage(String message) {
    if (!mounted) return;

    if (message == 'playing:true') {
      setState(() {
        _isPlaying = true;
      });
      widget.onPlayingChanged?.call(true);
    } else if (message == 'playing:false') {
      setState(() {
        _isPlaying = false;
      });
      widget.onPlayingChanged?.call(false);
    } else if (message.startsWith('error:')) {
      final error = message.substring(6);
      setState(() {
        _hasError = true;
        _errorMessage = error;
      });
      widget.onError?.call(error);
    } else if (message == 'completed') {
      widget.onCompleted?.call();
    } else if (message.startsWith('position:')) {
      final seconds = double.tryParse(message.substring(9));
      if (seconds != null) {
        widget.onPositionChanged?.call(
          Duration(milliseconds: (seconds * 1000).toInt()),
        );
      }
    }
  }

  void setVisible(bool visible) {
    final iframe = web.document.querySelector('iframe[srcdoc*="video"]')
        as web.HTMLIFrameElement?;
    if (iframe != null) {
      iframe.style.opacity = visible ? '1' : '0';
      iframe.style.pointerEvents = visible ? 'auto' : 'none';
    }
  }

  void requestPiP() {
    // Execute PiP request via postMessage to iframe
    final iframe =
        web.document.querySelector('iframe[srcdoc*="requestVideoPiP"]')
            as web.HTMLIFrameElement?;
    if (iframe != null && iframe.contentWindow != null) {
      iframe.contentWindow!.postMessage('requestPiP'.toJS, '*'.toJS);
    }
  }

  void play() {
    final iframe = web.document.querySelector('iframe[srcdoc*="video"]')
        as web.HTMLIFrameElement?;
    if (iframe != null && iframe.contentWindow != null) {
      iframe.contentWindow!.postMessage('play'.toJS, '*'.toJS);
    }
  }

  void pause() {
    final iframe = web.document.querySelector('iframe[srcdoc*="video"]')
        as web.HTMLIFrameElement?;
    if (iframe != null && iframe.contentWindow != null) {
      iframe.contentWindow!.postMessage('pause'.toJS, '*'.toJS);
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return _buildError();
    }

    // Just show the iframe - it handles its own loading
    return SizedBox.expand(
      child: HtmlElementView(viewType: _playerId!),
    );
  }

  Widget _buildError() {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 40),
                const SizedBox(height: 8),
                Text(
                  _errorMessage,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              onPressed: () => widget.onClose?.call(),
              icon: const Icon(Icons.close, color: Colors.white),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                minimumSize: const Size(32, 32),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get isPiPSupported => _isPiPSupported;
  bool get isPlaying => _isPlaying;
}
