import 'package:flutter/material.dart';
import 'package:tvninja/l10n/app_localizations.dart';

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
  State<WebVideoPlayerWidget> createState() => _WebVideoPlayerWidgetState();
}

class _WebVideoPlayerWidgetState extends State<WebVideoPlayerWidget> {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Text(
          AppLocalizations.of(context)!.videoNotAvailable,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
