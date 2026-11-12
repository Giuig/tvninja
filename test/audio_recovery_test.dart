import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/audio_recovery.dart';

/// Drives an [AudioRecovery] on fake time and records what it did.
class _Harness {
  _Harness(this.async, {this.failAttempts = false}) {
    final clock = async.getClock(DateTime(2026, 11, 12, 12));
    recovery = AudioRecovery(
      reopen: _reopen,
      onGiveUp: () => giveUps.add(async.elapsed),
      canRecover: () => canRecover,
      onStalled: () => stalls.add(async.elapsed),
      onRecovered: () => recoveries.add(async.elapsed),
      now: clock.now,
    );
  }

  final FakeAsync async;
  late final AudioRecovery recovery;

  /// When true every reopen reports a failure at once, like mpv's
  /// "Failed to open" error arriving for each attempt.
  bool failAttempts;

  /// What the service's "is an audio session still wanted" answers.
  bool canRecover = true;
  final reopens = <Duration>[];
  final giveUps = <Duration>[];
  final stalls = <Duration>[];
  final recoveries = <Duration>[];
  int _position = 0;

  Future<void> _reopen() async {
    reopens.add(async.elapsed);
    if (failAttempts) recovery.attemptFailed();
  }

  /// Audio flowing: playing, not buffering, position moving every second for
  /// [seconds].
  void play(int seconds) {
    recovery.playingChanged(true);
    recovery.bufferingChanged(false);
    for (var i = 0; i < seconds; i++) {
      recovery.positionChanged(Duration(seconds: ++_position));
      async.elapse(const Duration(seconds: 1));
    }
  }

  void elapse(int seconds) => async.elapse(Duration(seconds: seconds));
}

Duration _s(int seconds) => Duration(seconds: seconds);

void main() {
  group('reconnect budget', () {
    test('gives up after five failed attempts in a row, once', () {
      fakeAsync((async) {
        final h = _Harness(async, failAttempts: true);
        h.recovery.schedule();
        h.elapse(200);
        // 2, 4, 8, 16, 30 s of backoff between the attempts.
        expect(h.reopens, [_s(2), _s(6), _s(14), _s(30), _s(60)]);
        expect(h.giveUps, [_s(60)]);
        expect(h.recovery.isRecovering, isFalse);
      });
    });

    test('a recovered drop gives the budget back', () {
      fakeAsync((async) {
        final h = _Harness(async, failAttempts: true);
        h.recovery.schedule();
        h.elapse(31); // four attempts failed
        expect(h.reopens.length, 4);
        expect(h.recovery.attempt, 4);

        // The fifth works: audio flows, which is the only thing that counts.
        h.failAttempts = false;
        h.elapse(30); // fifth attempt fires at 60 s
        expect(h.reopens.length, 5);
        h.play(3);
        expect(h.recoveries.length, 1);
        expect(h.recovery.attempt, 0);
        expect(h.recovery.isRecovering, isFalse);

        // The next drop starts over at 2 s and is not given up on at once.
        h.failAttempts = true;
        final dropAt = async.elapsed;
        h.recovery.schedule();
        h.elapse(1);
        expect(h.reopens.length, 5, reason: 'first retry is 2 s out');
        h.elapse(1);
        expect(h.reopens.length, 6);
        expect(h.reopens.last - dropAt, _s(2));
        expect(h.giveUps, isEmpty);
        h.elapse(200);
        expect(h.reopens.length, 10);
        expect(h.giveUps.length, 1);
      });
    });

    test('a drop can be recovered from again and again', () {
      fakeAsync((async) {
        final h = _Harness(async);
        for (var drop = 1; drop <= 8; drop++) {
          h.recovery.schedule();
          h.elapse(3);
          expect(h.reopens.length, drop);
          h.play(2);
          expect(h.recoveries.length, drop);
        }
        expect(h.giveUps, isEmpty);
      });
    });

    test('after giving up, a fresh failure starts a fresh chain', () {
      fakeAsync((async) {
        final h = _Harness(async, failAttempts: true);
        h.recovery.schedule();
        h.elapse(61);
        expect(h.giveUps.length, 1);
        final before = h.reopens.length;
        h.recovery.schedule();
        h.elapse(3);
        expect(h.reopens.length, before + 1);
      });
    });
  });

  group('waiting for the outcome of an attempt', () {
    test('an attempt nobody reports on is given 15 s before the next', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.recovery.schedule();
        h.elapse(20);
        expect(h.reopens, [_s(2)], reason: 'open() returned, outcome unknown');
        h.elapse(1);
        // 2 s + 15 s waiting + 4 s backoff.
        expect(h.reopens, [_s(2), _s(21)]);
      });
    });

    test('a reopen that reports position 0 is not a recovery', () {
      fakeAsync((async) {
        final h = _Harness(async);
        // Stall path: mpv never stopped reporting playing / not buffering.
        h.play(5);
        h.elapse(24); // stalled, watchdog fires, chain scheduled
        h.elapse(3);
        expect(h.reopens.length, 1);
        h.recovery.positionChanged(Duration.zero); // what open() reports
        expect(h.recoveries, isEmpty);
        expect(h.recovery.attempt, 1);
        expect(h.recovery.isRecovering, isTrue);
        // Audio really flowing does count.
        h.recovery.positionChanged(const Duration(milliseconds: 250));
        expect(h.recoveries.length, 1);
        expect(h.recovery.attempt, 0);
      });
    });

    test('audio flowing ends the wait and the chain', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.recovery.schedule();
        h.elapse(5);
        h.play(100);
        expect(h.reopens.length, 1);
        expect(h.recoveries.length, 1);
        expect(h.giveUps, isEmpty);
      });
    });

    test('an error while a chain is waiting does not push the retry back', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.recovery.schedule();
        h.elapse(1);
        // What the stream error path does after its probe.
        h.recovery.schedule();
        h.elapse(1);
        expect(h.reopens, [_s(2)]);
      });
    });

    test('reset cancels a pending retry and an attempt in flight', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.recovery.schedule();
        h.elapse(3); // attempt 1 fired, waiting for its outcome
        h.recovery.reset();
        h.elapse(200);
        expect(h.reopens.length, 1);
        expect(h.giveUps, isEmpty);
        expect(h.recovery.attempt, 0);
      });
    });
  });

  group('stall detection with cache-pause=no (buffering never goes true)', () {
    test('position that stops moving starts a reconnect', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.play(5);
        // Last position event 1 s ago. Stalled after 4 s without movement,
        // then the watchdog's 20 s, then the first backoff.
        final stoppedAt = async.elapsed - _s(1);
        h.elapse(22);
        expect(h.stalls, isEmpty);
        h.elapse(1);
        expect(h.stalls.length, 1);
        expect(h.reopens, isEmpty);
        h.elapse(2);
        expect(h.reopens.length, 1);
        expect(h.reopens.single - stoppedAt, _s(4 + 20 + 2));
      });
    });

    test('healthy playback is never mistaken for a stall', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.play(180);
        expect(h.stalls, isEmpty);
        expect(h.reopens, isEmpty);
      });
    });

    test('a paused stream is not a stalled one', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.play(5);
        h.recovery.playingChanged(false);
        h.elapse(120);
        expect(h.stalls, isEmpty);
        expect(h.reopens, isEmpty);
      });
    });

    test('a stall that clears by itself does not reconnect', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.play(5);
        h.elapse(10); // 10 s without movement
        h.play(100);
        expect(h.stalls, isEmpty);
        expect(h.reopens, isEmpty);
      });
    });

    test('mpv reporting buffering also feeds the watchdog', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.recovery.playingChanged(true);
        h.recovery.bufferingChanged(true);
        h.elapse(19);
        expect(h.stalls, isEmpty);
        h.elapse(1);
        expect(h.stalls.length, 1);
      });
    });

    test('a stall is left alone once the session is no longer wanted', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.play(5);
        h.canRecover = false;
        h.elapse(120);
        expect(h.stalls, isEmpty);
        expect(h.reopens, isEmpty);
        expect(h.recovery.isRecovering, isFalse);
      });
    });

    test('a stall does not start a second chain over a running one', () {
      fakeAsync((async) {
        final h = _Harness(async, failAttempts: true);
        h.recovery.schedule();
        h.recovery.playingChanged(true);
        h.recovery.bufferingChanged(true);
        h.elapse(25);
        expect(h.stalls, isEmpty);
        expect(h.reopens, [_s(2), _s(6), _s(14)]);
      });
    });
  });

  group('PlaybackProgressMonitor', () {
    test('reports progress once per run of movement, not per event', () {
      fakeAsync((async) {
        var progress = 0;
        final stalls = <bool>[];
        final m = PlaybackProgressMonitor(
          onProgress: () => progress++,
          onStallChanged: stalls.add,
        )
          ..playingChanged(true)
          ..bufferingChanged(false);
        for (var i = 1; i <= 10; i++) {
          m.positionChanged(Duration(seconds: i));
          async.elapse(const Duration(seconds: 1));
        }
        expect(progress, 1);
        expect(stalls, isEmpty);

        async.elapse(const Duration(seconds: 4));
        expect(stalls, [true]);
        m.positionChanged(const Duration(seconds: 11));
        expect(stalls, [true, false]);
        expect(progress, 2);
      });
    });

    test('a repeated position is not movement', () {
      fakeAsync((async) {
        var progress = 0;
        final stalls = <bool>[];
        final m = PlaybackProgressMonitor(
          onProgress: () => progress++,
          onStallChanged: stalls.add,
        )
          ..playingChanged(true)
          ..bufferingChanged(false)
          ..positionChanged(const Duration(seconds: 7));
        expect(progress, 1);
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 1));
          m.positionChanged(const Duration(seconds: 7));
        }
        expect(stalls, [true]);
        expect(progress, 1);
      });
    });

    test('position zero is not movement', () {
      fakeAsync((async) {
        var progress = 0;
        final m = PlaybackProgressMonitor(
          onProgress: () => progress++,
          onStallChanged: (_) {},
        )
          ..playingChanged(true)
          ..bufferingChanged(false)
          ..positionChanged(const Duration(seconds: 9))
          ..positionChanged(Duration.zero);
        expect(progress, 1, reason: 'only the 9 s event');
        m.positionChanged(const Duration(milliseconds: 250));
        expect(progress, 1, reason: 'still the same run of movement');
      });
    });

    test('reset forgets the old stream and fires nothing', () {
      fakeAsync((async) {
        var calls = 0;
        final m = PlaybackProgressMonitor(
          onProgress: () => calls++,
          onStallChanged: (_) => calls++,
        )
          ..playingChanged(true)
          ..positionChanged(const Duration(seconds: 1));
        expect(calls, 1);
        m.reset();
        async.elapse(const Duration(seconds: 60));
        expect(calls, 1);
        expect(m.isStalled, isFalse);
      });
    });
  });
}
