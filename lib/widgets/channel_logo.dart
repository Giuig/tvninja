import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A channel logo, decoded at the size it is actually drawn at.
///
/// The decode size matters more than it looks. Playlist logos are whatever the
/// publisher uploaded — sampled from iptv-org's Italy list: 960x954, 960x936,
/// 960x960, 576x288, 512x511, 512x400 — while this widget draws them at roughly
/// 40 logical px in the channel list. Without a cache hint every one of those is
/// decoded at full size, so a single 960x954 logo costs about 3.7 MB of RGBA to
/// produce a thumbnail.
///
/// Measured on web before this hint existed, scrolling a 320-channel list: the
/// **first** pass through unseen rows ran 50% janky with a worst frame of 499.9
/// ms, while a second pass over the same rows was 0% janky and pinned to 16.7
/// ms. The scroll machinery was never the problem — the first build of each row
/// was.
///
/// Two more things every call site gets for free, which is why they live here
/// rather than at the call sites:
///
/// - **On web, a logo the browser refuses is retried through an image proxy.**
///   Plenty of logo hosts send no CORS headers, and the browser blocks those
///   images outright (51news.it, seen 2026-09-26). Direct first, proxy second,
///   and the order matters: the proxy cannot fetch from imgur at all (404 for
///   every i.imgur.com URL, measured the same day), while imgur sends
///   `Access-Control-Allow-Origin: *` and loads fine directly — and imgur hosts
///   a large share of playlist logos. Proxy-only, which the player's loading
///   screen used to do, lost every one of them.
/// - **Dark logos get a light tile.** Some publishers ship black-on-transparent
///   logos (TV8's is pure black), which vanish on this app's dark surfaces. See
///   [isDarkLogo] for the test; everything else is drawn exactly as before.
class ChannelLogo extends StatelessWidget {
  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget Function(BuildContext) fallbackBuilder;

  const ChannelLogo({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    required this.fallbackBuilder,
  });

  /// The proxied form of [url], tried on web when the direct load fails.
  /// images.weserv.nl answers with CORS headers whatever the origin sends.
  static String webProxyUrl(String url) =>
      'https://images.weserv.nl/?url=${Uri.encodeComponent(url)}&w=200&h=200&fit=contain';

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) return fallbackBuilder(context);

    // LayoutBuilder rather than requiring every caller to pass a size: three of
    // the five call sites size the logo through their layout instead (the
    // favourites tile hands it an AspectRatio box, for one), and they are on the
    // scrolling surfaces that need this most.
    return LayoutBuilder(
      builder: (context, constraints) {
        final logical = width ??
            (constraints.maxWidth.isFinite ? constraints.maxWidth : null);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final cacheWidth =
            (logical == null || logical <= 0) ? null : (logical * dpr).round();

        return _image(
          url!,
          cacheWidth,
          onError: kIsWeb
              ? (_) => _image(webProxyUrl(url!), cacheWidth,
                  onError: fallbackBuilder)
              : fallbackBuilder,
        );
      },
    );
  }

  Widget _image(
    String source,
    int? cacheWidth, {
    required Widget Function(BuildContext) onError,
  }) {
    return CachedNetworkImage(
      imageUrl: source,
      width: width,
      height: height,
      fit: fit,
      // Physical pixels, not logical: caching at logical size would look
      // soft on any 2x/3x screen, which trades a visible regression for the
      // performance win.
      //
      // Width only, deliberately. cached_network_image forwards both values
      // into ResizeImage, whose default policy treats them as *exact*
      // targets rather than a bounding box — so passing memCacheHeight as
      // well would squash a 512x63 banner into a square and distort it under
      // BoxFit.contain. Width alone preserves aspect ratio and already
      // covers every oversized logo measured above, which are square-ish.
      //
      // Flutter itself does have ResizeImagePolicy.fit, which would treat
      // the pair as a bounding box and make passing both safe — but
      // cached_network_image (3.4.1) hands the values to octo_image, which
      // calls ResizeImage.resizeIfNeeded without a policy argument, so the
      // default `exact` is the only reachable behaviour. Recorded so the
      // next reader does not have to re-derive it from package source.
      memCacheWidth: cacheWidth,
      // Replaces the default image widget, so it has to apply width,
      // height and fit itself — CachedNetworkImage no longer does.
      imageBuilder: (_, image) => _ContrastAwareLogo(
        cacheKey: source,
        image: image,
        width: width,
        height: height,
        fit: fit,
      ),
      errorWidget: (context, _, __) => onError(context),
    );
  }
}

/// Draws a decoded logo, on a light tile when [isDarkLogo] says it would
/// otherwise disappear.
///
/// The first frame shows the plain logo while the pixels are read; a dark logo
/// is invisible in that frame anyway, so the tile appearing is the only visible
/// change. The verdict is cached per URL, so each logo is measured once per run.
class _ContrastAwareLogo extends StatefulWidget {
  final String cacheKey;
  final ImageProvider image;
  final double? width;
  final double? height;
  final BoxFit fit;

  const _ContrastAwareLogo({
    required this.cacheKey,
    required this.image,
    required this.width,
    required this.height,
    required this.fit,
  });

  @override
  State<_ContrastAwareLogo> createState() => _ContrastAwareLogoState();
}

class _ContrastAwareLogoState extends State<_ContrastAwareLogo> {
  static final Map<String, bool> _darkByUrl = {};

  /// Light enough to read any dark logo against, dim enough not to glare on a
  /// black screen.
  static const Color _tileColor = Color(0xFFE8E8E8);

  bool _dark = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_ContrastAwareLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _stopListening();
      _start();
    }
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  void _start() {
    final known = _darkByUrl[widget.cacheKey];
    _dark = known ?? false;
    if (known != null) return;
    final key = widget.cacheKey;
    final stream = widget.image.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        // Our own handle: the stream may drop its image once no listener is
        // left, and reading the pixels is asynchronous.
        final image = info.image.clone();
        _stopListening();
        _measure(key, image);
      },
      onError: (_, __) => _stopListening(),
    );
    // Assigned before addListener: an image already in the cache calls back
    // synchronously from inside it, and that callback has to find the
    // listener it is removing.
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  Future<void> _measure(String key, ui.Image image) async {
    var dark = false;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data != null) {
        dark = isDarkLogo(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
    } catch (_) {
      // Pixels unreadable (a web image that is not CORS-clean, say): draw the
      // logo as it is, which is what happened before this check existed.
    } finally {
      image.dispose();
    }
    _darkByUrl[key] = dark;
    if (mounted && key == widget.cacheKey && dark != _dark) {
      setState(() => _dark = dark);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_dark) {
      return Image(
        image: widget.image,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
      );
    }
    // Same outer box as the plain logo, so no caller's layout moves.
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.min(constraints.maxWidth, constraints.maxHeight);
          final unit = side.isFinite ? side : 40.0;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: _tileColor,
              borderRadius: BorderRadius.circular(unit * 0.15),
            ),
            child: Padding(
              padding: EdgeInsets.all(unit * 0.1),
              child: Image(image: widget.image, fit: widget.fit),
            ),
          );
        },
      ),
    );
  }
}

/// Linear-light value of each 8-bit sRGB channel level.
final List<double> _linear = List<double>.generate(256, (v) {
  final s = v / 255;
  return s <= 0.04045
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
});

/// Whether a logo, given as raw RGBA bytes, would be all but invisible on a
/// black background.
///
/// Dark means: at least 90% of the opaque pixels (alpha > 128) have a relative
/// luminance under 0.03 — a WCAG contrast of about 1.6:1 or less against black,
/// where 3:1 is the floor for graphics. Pure black (TV8) and near-black navy
/// qualify; saturated colours do not, even dark-looking red, whose luminance
/// is 0.21. A black badge with white lettering usually has more than 10% light
/// pixels and stays as it is, since its lettering is already readable.
///
/// Samples at most about 4096 pixels, so a large logo costs the same as a
/// small one.
@visibleForTesting
bool isDarkLogo(Uint8List rgba) {
  final pixels = rgba.length ~/ 4;
  if (pixels == 0) return false;
  final stride = math.max(1, pixels ~/ 4096);
  var opaque = 0;
  var dark = 0;
  for (var p = 0; p < pixels; p += stride) {
    final i = p * 4;
    if (rgba[i + 3] <= 128) continue;
    opaque++;
    final luminance = 0.2126 * _linear[rgba[i]] +
        0.7152 * _linear[rgba[i + 1]] +
        0.0722 * _linear[rgba[i + 2]];
    if (luminance < 0.03) dark++;
  }
  return opaque > 0 && dark >= opaque * 0.9;
}
