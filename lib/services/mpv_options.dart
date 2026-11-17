import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'video/stream_format_hint.dart';

/// Cached emulator detection result — computed once per app session.
bool? _cachedIsEmulator;

/// The audio outputs mpv is asked to try on Android, in order: Java
/// `AudioTrack` first, OpenSL ES kept behind it so a device where the
/// AudioTrack output fails to open still plays.
///
/// Why not media_kit's own `ao=opensles`: mpv's OpenSL ES output is created
/// with the platform's default performance mode, which is the low-latency one.
/// That puts the stream on the fast mixer, and the fast path bypasses the
/// pre/post-processing the device applies to a normal track (Samsung's EQ,
/// measured on an S24 Ultra 2026-11-17: video mode, an ExoPlayer AudioTrack,
/// was processed and sound mode, the OpenSL ES player, was not, so sound mode
/// played louder). The AudioTrack output builds a plain `MODE_STREAM` track
/// with `USAGE_MEDIA` and no performance-mode flag, so it is a normal track.
const String androidAudioOutputs = 'audiotrack,opensles';

/// Applies libmpv options tuned for live IPTV/HLS streams.
///
/// Key settings:
/// - Small forward cache (live streams can't prefill much)
/// - Zero back-buffer (prevents demuxer from replaying old audio packets
///   at TS segment boundaries — the root cause of "audio repeating chunks")
/// - cache-pause disabled (live cache is always "low"; pausing causes
///   micro-stutters when the audio pipeline resets on resume)
/// - Emulator-aware: disables hardware decode on emulators to prevent freeze
Future<void> applyLiveStreamMpvOptions(Player player,
    {bool soundOnly = false}) async {
  if (kIsWeb) return;
  try {
    final native = player.platform as dynamic;
    // Cache — slightly increased for faster initial connection
    native.setProperty('cache', 'yes');
    native.setProperty('cache-secs', '6');
    // 8 MiB is sized for video. A sound-mode player decodes audio only and
    // needs on the order of 96 KB, so the rest is read-ahead of bytes nothing
    // will ever use — paid again on every reconnect, which on a flaky mobile
    // link is often. 1 MiB keeps a wide safety factor over that ~96 KB while
    // cutting the ceiling eightfold. Video keeps 8 MiB untouched.
    native.setProperty('demuxer-max-bytes', soundOnly ? '1MiB' : '8MiB');
    // CRITICAL: no back-buffer — prevents TS demuxer from replaying old
    // audio packets when it re-reads across segment boundaries
    native.setProperty('demuxer-max-back-bytes', '0');
    // CRITICAL: never pause on low cache (live streams can't prefill)
    native.setProperty('cache-pause', 'no');
    native.setProperty('cache-pause-initial', 'no');
    // TESTED & REVERTED: hls-bitrate='min' (force lowest HLS variant).
    //
    // READ THIS BEFORE TREATING THE SOUND-MODE PIN AS A REGRESSION OF IT
    // (2026-11-17). Sound mode now opens the lowest-bandwidth variant (or a
    // separate audio rendition) by owner ruling — see `rules/tvninja.md`,
    // "sound mode takes the smallest stream". That does NOT contradict the
    // revert below, on two counts. The revert was measured in **video** mode,
    // where the mid-GOP join errors it found ("non-existing PPS referenced",
    // "decode_slice_header error") are video-decode errors; sound mode decodes
    // no video at all, so they are unreachable there. And it selected inside
    // mpv with this property, which applies to whatever mpv is given; the pin
    // instead resolves the master in Dart and hands mpv a single media
    // playlist, so mpv does no selecting. This property stays unset.
    //
    // Hypothesis was that mpv defaulting to the top bitrate variant (RAI:
    // 1920x1080/~5.7Mbps) explained the gap vs. simpler low-bitrate sources
    // (TV8: 854x480, opens in ~1.5s). Measured result: forcing RAI down to
    // its lowest 768x432 variant did NOT reduce tap-to-first-frame time
    // (~3.4s, same as before) and introduced real decode errors joining
    // mid-GOP ("non-existing PPS referenced", "decode_slice_header error").
    // Net negative — same speed, added corruption risk. The RAI/Mediaset
    // vs TV8 gap is real but isn't explained by bitrate/resolution.
    // Reduced network timeout for faster initial connection failure
    native.setProperty('network-timeout', '5');
    // No `reconnect-*` options here: those are libavformat's http options, not
    // mpv properties, so setting them did nothing. Recovery from a dropped
    // stream lives above mpv: `video/reconnect_controller.dart` for the
    // foreground player, `audio_recovery.dart` for background audio.
    // Limit lavf probing — fallback for streams whose format can't be guessed
    // from the URL. applyFormatHint() sets demuxer-lavf-format before open()
    // to skip probing entirely for known formats (.m3u8 → hls, .ts → mpegts).
    // demuxer-lavf-probesize is a byte count (mpv default: autodetect).
    native.setProperty('demuxer-lavf-probesize', '250000');
    // demuxer-lavf-analyzeduration is in SECONDS, not microseconds (mpv
    // default: 5s). The previous value ('250000') was 250000 SECONDS —
    // out of range, silently rejected, so mpv fell back to its 5s default
    // on every channel open. This was the dominant cost in tap-to-first-frame
    // latency (measured ~3.4-4.7s gap matching the 5s default almost exactly).
    native.setProperty('demuxer-lavf-analyzeduration', '0.5');

    // Android only; every other platform keeps its own default output.
    // Awaited, unlike the sets above: it reads `ao` first, and every caller
    // awaits this function before the first `loadfile`.
    if (defaultTargetPlatform == TargetPlatform.android) {
      await applyAndroidAudioOutput(native);
    }

    // Emulator-aware hardware decode: disable on emulators to prevent freeze.
    // Result is cached after the first call — DeviceInfoPlugin is an async
    // platform call and running it on every Player() creation adds 50-150 ms.
    _cachedIsEmulator ??= await _isEmulator();
    if (_cachedIsEmulator!) {
      native.setProperty('hwdec', 'no');
      native.setProperty('vd-lavc-threads', '4');
      native.setProperty('framedrop', 'vo');
    } else {
      native.setProperty('hwdec', 'auto-safe');
      // Fast decoder path — skips non-essential steps; imperceptible quality
      // difference on compressed live TV content.
      native.setProperty('vd-lavc-fast', 'yes');
    }
  } catch (_) {
    // Non-fatal: platform doesn't support setProperty
  }
}

/// Points mpv at [androidAudioOutputs] on [native] (a media_kit `NativePlayer`).
///
/// Same post-init `setProperty` mechanism media_kit itself uses for its
/// `ao=opensles` default: `setProperty` waits for the player's initialisation,
/// which is where media_kit writes that default, so this write lands after it
/// and wins. No output is opened before the first `loadfile`.
///
/// Left alone when media_kit chose `ao=null` (an emulator at API <= 25, where
/// it switches the audio off because OpenSL ES is broken there): turning audio
/// back on would undo that on purpose. If `ao` cannot be read the list is set
/// anyway, because that is the default path.
@visibleForTesting
Future<void> applyAndroidAudioOutput(dynamic native) async {
  try {
    String? current;
    try {
      current = await (native.getProperty('ao') as Future)
          .timeout(const Duration(milliseconds: 500)) as String?;
    } catch (_) {
      current = null;
    }
    if (current == 'null') return;
    await (native.setProperty('ao', androidAudioOutputs) as Future);
  } catch (_) {
    // Non-fatal: mpv keeps the output media_kit chose.
  }
}

/// Sets `demuxer-lavf-format` on [player] based on [url]'s path suffix so
/// libav can skip format probing entirely (saves 200-600 ms on each open).
///
/// Synchronous — no async/await so it doesn't yield to the event loop before
/// player.open() is called (an unnecessary 50-100 ms penalty on each switch).
void applyFormatHint(Player player, String url) {
  if (kIsWeb) return;
  try {
    final native = player.platform as dynamic;
    final fmt = switch (guessStreamFormat(url)) {
      StreamFormatHint.hls => 'hls',
      StreamFormatHint.mpegTs => 'mpegts',
      StreamFormatHint.mp4 => 'mp4',
      // Empty string means "keep sniffing" (see the demuxer-lavf-probesize
      // comment above) — same as unknown. mpv has no dedicated demuxer name
      // to force for a bare MP3/AAC/etc. stream; its own lavf probing
      // handles those correctly already, unlike ExoPlayer's format-hint gate.
      StreamFormatHint.audio => '',
      StreamFormatHint.unknown => '',
    };
    native.setProperty('demuxer-lavf-format', fmt);
  } catch (_) {}
}

/// Detects if the app is running on an emulator.
/// Checks multiple signals since some emulators spoof isPhysicalDevice.
Future<bool> _isEmulator() async {
  try {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;

    // Debug: log device info for troubleshooting
    debugPrint(
        '[MPV] Device: ${androidInfo.model}, product: ${androidInfo.product}');

    // Basic check (may be spoofed by some emulators)
    if (androidInfo.isPhysicalDevice == false) return true;

    // Check for emulator indicators in device properties
    final model = androidInfo.model.toLowerCase();
    final product = androidInfo.product.toLowerCase();
    final hardware = androidInfo.hardware.toLowerCase();
    final board = androidInfo.board.toLowerCase();
    final brand = androidInfo.brand.toLowerCase();
    final device = androidInfo.device.toLowerCase();
    final host = androidInfo.host.toLowerCase();
    final fingerprint = androidInfo.fingerprint.toLowerCase();

    // Check for suspicious product suffixes (xxx often indicates spoofed)
    if (product.endsWith('xxx') || product.endsWith('userdebug')) {
      return true;
    }

    // Common emulator indicators
    final emulatorIndicators = [
      'generic', // Generic device
      'emulator', // Explicit emulator
      'sdk', // SDK build
      'goldfish', // Android emulator
      'ranchu', // Android emulator
      'vbox', // VirtualBox
      'nox', // NoxPlayer
      'bluestacks', // BlueStacks
      'bst', // BlueStacks short
      'vbox86', // VirtualBox x86
      'ttvm_x86', // TTVM emulator
      'msi', // MSI App Player (BlueStacks-based, reports as msi)
      'ldplayer', // LDPlayer
    ];

    final allChecks =
        '$model $product $hardware $board $brand $device $host $fingerprint';

    for (final indicator in emulatorIndicators) {
      if (allChecks.contains(indicator)) {
        return true;
      }
    }

    return false;
  } catch (_) {
    return false; // If detection fails, assume real device
  }
}
