import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/buffering_watchdog.dart';

/// Drives a [BufferingWatchdog] on fake time and records what it decided.
class _Harness {
  _Harness(this.async) {
    final clock = async.getClock(DateTime(2026, 10, 29, 12));
    watchdog = BufferingWatchdog(
      hasStartedPlaying: () => started,
      onFirstLoadTimeout: () => firstLoadTimeouts++,
      onStalled: () => stalls.add(async.elapsed),
      now: clock.now,
    );
  }

  final FakeAsync async;
  late final BufferingWatchdog watchdog;
  bool started = true;
  int firstLoadTimeouts = 0;
  final stalls = <Duration>[];

  /// One stall of [stalled], then [playing] of playback.
  void stall(Duration stalled, {Duration playing = Duration.zero}) {
    watchdog.bufferingChanged(true);
    async.elapse(stalled);
    watchdog.bufferingChanged(false);
    async.elapse(playing);
  }
}

const _ms = Duration(milliseconds: 1);

void main() {
  test('a stream that never starts times out after 15s', () {
    fakeAsync((async) {
      final h = _Harness(async)..started = false;
      h.watchdog.bufferingChanged(true);
      async.elapse(const Duration(seconds: 14));
      expect(h.firstLoadTimeouts, 0);
      async.elapse(const Duration(seconds: 1));
      expect(h.firstLoadTimeouts, 1);
      expect(h.stalls, isEmpty);
    });
  });

  test('one 20s rebuffer of a playing stream reconnects', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.watchdog.bufferingChanged(true);
      async.elapse(const Duration(seconds: 19));
      expect(h.stalls, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(h.stalls, [const Duration(seconds: 20)]);
    });
  });

  test('the live-edge sawtooth reconnects within 16s', () {
    // What MSI App Player logged on 2026-10-26 and 10-29: about 3.5s stalled
    // and 0.5s playing, once per 4s HLS segment, with ms-long flips in
    // between. Before this fix it only reconnected after 40s+, once one
    // stall happened to reach 20s.
    fakeAsync((async) {
      final h = _Harness(async);
      for (var i = 0; i < 15; i++) {
        h.stall(_ms * 3500, playing: _ms * 20);
        h.stall(_ms * 20, playing: _ms * 460);
      }
      expect(h.stalls, isNotEmpty);
      expect(h.stalls.first, lessThanOrEqualTo(const Duration(seconds: 16)));
    });
  });

  test('a single 3s rebuffer does not reconnect', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.stall(const Duration(seconds: 3), playing: const Duration(minutes: 2));
      expect(h.stalls, isEmpty);
    });
  });

  test('a few short rebuffers spread over a minute do not reconnect', () {
    fakeAsync((async) {
      final h = _Harness(async);
      for (var i = 0; i < 3; i++) {
        h.stall(const Duration(seconds: 2),
            playing: const Duration(seconds: 18));
      }
      h.stall(const Duration(seconds: 2), playing: const Duration(minutes: 1));
      expect(h.stalls, isEmpty);
    });
  });

  test('reset() forgets earlier stalls, so a reconnected stream starts clean',
      () {
    fakeAsync((async) {
      final h = _Harness(async);
      for (var i = 0; i < 3; i++) {
        h.stall(const Duration(seconds: 3), playing: _ms * 500);
      }
      h.watchdog.reset();
      for (var i = 0; i < 2; i++) {
        h.stall(const Duration(seconds: 3), playing: _ms * 500);
      }
      expect(h.stalls, isEmpty);
    });
  });
}
