import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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
    return CachedNetworkImage(
      imageUrl: url!,
      width: width,
      height: height,
      fit: fit,
      errorWidget: (_, __, ___) => fallbackBuilder(context),
    );
  }
}
