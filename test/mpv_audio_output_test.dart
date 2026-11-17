import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:tvninja/services/mpv_options.dart';

/// Stands in for media_kit's `NativePlayer`: the app reaches it dynamically
/// (`player.platform as dynamic`), so only these two members matter.
class _RecordingNative extends Fake implements mk.PlatformPlayer {
  _RecordingNative({this.ao = 'opensles', this.readThrows = false});

  /// What media_kit left in `ao` (its own default is `opensles`).
  String ao;
  final bool readThrows;
  final writes = <String, String>{};
  final order = <String>[];

  Future<String> getProperty(String name) async {
    order.add('get $name');
    if (readThrows) throw StateError('unreadable');
    return name == 'ao' ? ao : '';
  }

  Future<void> setProperty(String name, String value) async {
    order.add('set $name');
    writes[name] = value;
  }
}

class _FakePlayer extends Fake implements mk.Player {
  _FakePlayer(this._native);
  final _RecordingNative _native;
  @override
  mk.PlatformPlayer? get platform => _native;
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the list is audiotrack first with opensles kept as the fallback', () {
    expect(androidAudioOutputs, 'audiotrack,opensles');
  });

  group('applyAndroidAudioOutput', () {
    test('overrides the opensles default media_kit wrote', () async {
      final native = _RecordingNative();
      await applyAndroidAudioOutput(native);
      expect(native.writes['ao'], 'audiotrack,opensles');
    });

    test('reads ao before it writes it (after media_kit has set its own)',
        () async {
      final native = _RecordingNative();
      await applyAndroidAudioOutput(native);
      expect(native.order, ['get ao', 'set ao']);
    });

    test('leaves ao=null alone: media_kit switched the audio off on purpose',
        () async {
      final native = _RecordingNative(ao: 'null');
      await applyAndroidAudioOutput(native);
      expect(native.writes, isEmpty);
    });

    test('still sets the list when ao cannot be read', () async {
      final native = _RecordingNative(readThrows: true);
      await applyAndroidAudioOutput(native);
      expect(native.writes['ao'], 'audiotrack,opensles');
    });

    test('never throws when the player has no property access', () async {
      await applyAndroidAudioOutput(Object());
    });
  });

  group('applyLiveStreamMpvOptions', () {
    test('sets the output list on Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final native = _RecordingNative();
      await applyLiveStreamMpvOptions(_FakePlayer(native));
      expect(native.writes['ao'], 'audiotrack,opensles');
      // The existing options are still applied around it.
      expect(native.writes['cache'], 'yes');
      expect(native.writes['hwdec'], isNotNull);
    });

    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      test('does not touch ao on $platform', () async {
        debugDefaultTargetPlatformOverride = platform;
        final native = _RecordingNative();
        await applyLiveStreamMpvOptions(_FakePlayer(native));
        expect(native.writes.containsKey('ao'), isFalse);
        expect(native.writes['cache'], 'yes');
      });
    }
  });
}
