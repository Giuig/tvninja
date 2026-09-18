import 'package:cached_network_image/cached_network_image.dart';
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

        return CachedNetworkImage(
          imageUrl: url!,
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
          errorWidget: (_, __, ___) => fallbackBuilder(context),
        );
      },
    );
  }
}
