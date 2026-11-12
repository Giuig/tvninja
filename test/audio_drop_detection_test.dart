import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/audio_recovery.dart';

Duration _s(int seconds) => Duration(seconds: seconds);

/// A recovery that records when it reopened.
class _Rig {
  _Rig(this.async) {
    recovery = AudioRecovery(
      reopen: () async => reopens.add(async.elapsed),
      onGiveUp: () {},
    );
  }

  final FakeAsync async;
  late final AudioRecovery recovery;
  final reopens = <Duration>[];

  /// Audio has flowed once.
  void hadPlayed() {
    recovery.playingChanged(true);
    recovery.bufferingChanged(false);
    recovery.positionChanged(_s(5));
  }

  // The service's two handlers, minus mpv.
  void liveEnd() {
    recovery.attemptFailed();
    recovery.schedule();
  }

  void errorLine() {
    recovery.attemptFailed();
    final action = streamErrorAction(
      mayReconnect: true,
      hasPlayed: recovery.hasProgressed,
      failedAttempts: recovery.attempt,
      probeInFlight: false,
    );
    if (action == StreamErrorAction.reconnect) recovery.schedule();
  }
}

void main() {
  group('what a completed event means (streamEndAction)', () {
    test('a live stream (no duration) that ends is a drop to reconnect', () {
      expect(
        streamEndAction(duration: Duration.zero, mayReconnect: true),
        StreamEndAction.reconnect,
      );
    });

    test('a file (has a duration) that ends is replayed, as before', () {
      expect(
        streamEndAction(duration: _s(212), mayReconnect: true),
        StreamEndAction.replay,
      );
    });

    test('a file is replayed even when reconnecting is not wanted', () {
      // Unchanged behaviour: only the live branch is gated on the session.
      expect(
        streamEndAction(duration: _s(212), mayReconnect: false),
        StreamEndAction.replay,
      );
    });

    test('a live stream ending after stop / give-up / failed start is left',
        () {
      expect(
        streamEndAction(duration: Duration.zero, mayReconnect: false),
        StreamEndAction.ignore,
      );
    });

    test('a negative duration is still "unknown"', () {
      expect(isLiveDuration(const Duration(milliseconds: -1)), isTrue);
      expect(isLiveDuration(const Duration(milliseconds: 1)), isFalse);
    });
  });

  group('what a stream error means (streamErrorAction)', () {
    StreamErrorAction act({
      bool mayReconnect = true,
      bool hasPlayed = true,
      int failedAttempts = 0,
      bool probeInFlight = false,
    }) =>
        streamErrorAction(
          mayReconnect: mayReconnect,
          hasPlayed: hasPlayed,
          failedAttempts: failedAttempts,
          probeInFlight: probeInFlight,
        );

    test('the error of a drop reconnects with no probe in front', () {
      expect(act(failedAttempts: 0), StreamErrorAction.reconnect);
    });

    test('the first failed reconnect still does not probe', () {
      expect(act(failedAttempts: 1), StreamErrorAction.reconnect);
    });

    test('the second failed reconnect in a row probes', () {
      expect(act(failedAttempts: 2), StreamErrorAction.probe);
      expect(act(failedAttempts: 5), StreamErrorAction.probe);
    });

    test('a stream that never played is probed at once (dead URL)', () {
      expect(act(hasPlayed: false, failedAttempts: 0), StreamErrorAction.probe);
    });

    test('nothing is done when reconnecting is not wanted', () {
      expect(act(mayReconnect: false), StreamErrorAction.ignore);
      expect(
        act(mayReconnect: false, hasPlayed: false, failedAttempts: 3),
        StreamErrorAction.ignore,
      );
    });

    test('further lines of one failure while its probe runs do nothing', () {
      expect(
        act(hasPlayed: false, probeInFlight: true),
        StreamErrorAction.ignore,
      );
      expect(
        act(failedAttempts: 2, probeInFlight: true),
        StreamErrorAction.ignore,
      );
    });

    test('the probe threshold is two', () {
      expect(probeAfterFailedAttempts, 2);
    });
  });

  group('one reconnect per drop', () {
    test('an end plus two error lines make one chain and one attempt', () {
      fakeAsync((async) {
        final r = _Rig(async)..hadPlayed();
        expect(r.recovery.hasProgressed, isTrue);

        r.liveEnd();
        r.errorLine();
        r.errorLine();
        expect(r.recovery.isRecovering, isTrue);
        expect(r.recovery.attempt, 0);

        async.elapse(_s(2));
        expect(r.reopens, [_s(2)]);
        expect(r.recovery.attempt, 1);

        // Nothing is queued behind it: the next attempt is the backoff after
        // this one, not a second copy of the first.
        async.elapse(_s(1));
        expect(r.reopens.length, 1);
      });
    });

    test('error lines first, then the end, still make one chain', () {
      fakeAsync((async) {
        final r = _Rig(async)..hadPlayed();

        r.errorLine();
        r.errorLine();
        r.liveEnd();

        async.elapse(_s(2));
        expect(r.reopens.length, 1);
        expect(r.recovery.attempt, 1);
      });
    });

    test('an end that arrives while an attempt runs ends that attempt only',
        () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.recovery.schedule();
        async.elapse(_s(2)); // attempt 1 in flight
        expect(r.reopens.length, 1);

        r.liveEnd(); // the reopened stream ended at once
        async.elapse(_s(4)); // backoff for attempt 2
        expect(r.reopens, [_s(2), _s(6)]);
        expect(r.recovery.attempt, 2);
      });
    });

    test('error lines on a reconnect do not push the pending retry back', () {
      fakeAsync((async) {
        final r = _Rig(async)..hadPlayed();
        r.liveEnd();
        async.elapse(_s(1));
        r.errorLine();
        async.elapse(_s(1));
        expect(r.reopens, [_s(2)]);
      });
    });
  });

  group('has the stream worked (hasProgressed / epoch)', () {
    test('false for a stream that never produced audio', () {
      fakeAsync((async) {
        final r = _Rig(async).recovery;
        r.playingChanged(true);
        r.bufferingChanged(false);
        r.positionChanged(Duration.zero); // reopen's own zero: not progress
        expect(r.hasProgressed, isFalse);
      });
    });

    test('true once audio flowed, kept through the reconnects of a drop', () {
      fakeAsync((async) {
        final rig = _Rig(async)..hadPlayed();
        expect(rig.recovery.hasProgressed, isTrue);
        rig.recovery.schedule();
        async.elapse(_s(2));
        expect(rig.recovery.hasProgressed, isTrue);
      });
    });

    test('reset (new load, stop, give-up) forgets it', () {
      fakeAsync((async) {
        final rig = _Rig(async)..hadPlayed();
        rig.recovery.reset();
        expect(rig.recovery.hasProgressed, isFalse);
      });
    });

    test('epoch moves on progress and on reset, not on a failure', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        final r = rig.recovery;
        final e0 = r.epoch;
        r.attemptFailed();
        r.schedule();
        expect(r.epoch, e0);

        // Movement while a reconnect is pending is not progress (a stray
        // position event after an error), so it leaves the epoch alone.
        rig.hadPlayed();
        expect(r.epoch, e0);

        // A stop or a new play clears the chain; then audio flowing on a
        // fresh stream is progress.
        r.reset();
        final e1 = r.epoch;
        expect(e1, isNot(e0));
        rig.hadPlayed();
        final e2 = r.epoch;
        expect(e2, isNot(e1));

        r.reset();
        expect(r.epoch, isNot(e2));
      });
    });
  });
}
