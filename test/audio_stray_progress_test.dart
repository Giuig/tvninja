import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/audio_recovery.dart';

Duration _s(int seconds) => Duration(seconds: seconds);
Duration _ms(int ms) => Duration(milliseconds: ms);

/// An [AudioRecovery] wired the way the service wires it, on fake time.
///
/// Reproduces what a device run showed: a dropped live stream ends, mpv's
/// replay of it is refused ("Cannot seek in this stream"), the error handler
/// starts the reconnect chain, and about 40 ms later mpv reports one more
/// position event although nothing is playing. That event must not be taken
/// for the stream having recovered.
class _Rig {
  _Rig(this.async, {this.attemptsFail = false}) {
    final clock = async.getClock(DateTime(2026, 11, 12, 12));
    recovery = AudioRecovery(
      reopen: _reopen,
      onGiveUp: () => giveUps.add(async.elapsed),
      onRecovered: () => recoveries.add(async.elapsed),
      now: clock.now,
    );
  }

  final FakeAsync async;
  late final AudioRecovery recovery;

  /// Every reopen is answered by a stream error at once (a dead URL, a 404).
  bool attemptsFail;

  final reopens = <Duration>[];
  final giveUps = <Duration>[];
  final recoveries = <Duration>[];

  Future<void> _reopen() async {
    reopens.add(async.elapsed);
    if (attemptsFail) errorLine();
  }

  /// The stream has been playing for a while.
  void hadPlayed() {
    recovery.playingChanged(true);
    recovery.bufferingChanged(false);
    for (var i = 1; i <= 10; i++) {
      recovery.positionChanged(_s(i));
      async.elapse(_s(1));
    }
  }

  /// What the service does with one mpv error event (no probe involved: the
  /// stream has played and no attempt has failed yet).
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

  /// The drop as the device logged it: mpv reports end of file (playing off,
  /// a buffering blip), the replay is refused, playing goes back on, then the
  /// two error lines.
  void dropByRefusedReplay() {
    recovery.playingChanged(false);
    recovery.bufferingChanged(true);
    recovery.bufferingChanged(false);
    recovery.playingChanged(true);
    errorLine();
    errorLine();
  }

  void elapse(Duration d) => async.elapse(d);
}

void main() {
  group('a stray position event right after an error', () {
    test('does not cancel the reconnect the error just scheduled', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.hadPlayed();
        r.dropByRefusedReplay();
        expect(r.recovery.isRecovering, isTrue);

        // Measured: 38-46 ms later, one position event.
        r.elapse(_ms(40));
        r.recovery.positionChanged(const Duration(milliseconds: 10400));
        expect(r.recoveries, isEmpty, reason: 'nothing is playing');
        expect(r.recovery.isRecovering, isTrue);

        final dropAt = async.elapsed - _ms(40);
        r.elapse(_s(3));
        expect(r.reopens.length, 1, reason: 'the armed retry still fires');
        expect(r.reopens.single - dropAt, _s(2));
      });
    });

    test('a burst of them does not count either', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.hadPlayed();
        r.dropByRefusedReplay();
        for (var i = 0; i < 5; i++) {
          r.elapse(_ms(40));
          r.recovery.positionChanged(Duration(milliseconds: 10400 + i * 40));
        }
        expect(r.recoveries, isEmpty);
        r.elapse(_s(3));
        expect(r.reopens.length, 1);
      });
    });

    test('the retry that follows still counts when audio really flows', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.hadPlayed();
        r.dropByRefusedReplay();
        r.elapse(_ms(40));
        r.recovery.positionChanged(const Duration(milliseconds: 10400));
        r.elapse(_s(3));
        expect(r.reopens.length, 1);

        // The reopened stream: position 0 first, then audio.
        r.recovery.bufferingChanged(true);
        r.recovery.positionChanged(Duration.zero);
        r.recovery.bufferingChanged(false);
        r.recovery.positionChanged(_ms(300));
        expect(r.recoveries.length, 1);
        expect(r.recovery.attempt, 0);
        expect(r.recovery.isRecovering, isFalse);
      });
    });

    test('a stream that then keeps failing still ends at the give-up, not in '
        'a hang (played, then 404)', () {
      fakeAsync((async) {
        final r = _Rig(async, attemptsFail: true);
        r.hadPlayed();
        r.dropByRefusedReplay();
        r.elapse(_ms(40));
        r.recovery.positionChanged(const Duration(milliseconds: 10400));
        // The core goes idle again, so the stall detector has nothing to
        // watch (on the device nothing rescued the session either).
        r.recovery.playingChanged(false);
        r.elapse(_s(200));
        // 2, 4, 8, 16, 30 s of backoff after the drop at 10 s.
        expect(r.reopens.length, 5);
        expect(r.giveUps.length, 1);
        expect(r.recovery.isRecovering, isFalse);
      });
    });
  });

  group('movement with no attempt running', () {
    test('counts once it is sustained: the stream healed by itself', () {
      fakeAsync((async) {
        // Attempts fail at 2 s and 6 s after the drop; the next is at 14 s.
        final r = _Rig(async, attemptsFail: true);
        r.hadPlayed();
        r.dropByRefusedReplay();
        r.elapse(_s(7));
        expect(r.reopens.length, 2);
        r.attemptsFail = false;

        // The old stream starts moving again at 7 s. Two seconds of movement
        // is not enough, three is.
        r.recovery.positionChanged(_s(20));
        for (var i = 1; i <= 2; i++) {
          r.elapse(_s(1));
          r.recovery.positionChanged(_s(20 + i));
        }
        expect(r.recoveries, isEmpty);
        r.elapse(_s(1));
        r.recovery.positionChanged(_s(23));
        expect(r.recoveries.length, 1);
        expect(r.recovery.isRecovering, isFalse);
        r.elapse(_s(5)); // past the 14 s retry
        expect(r.reopens.length, 2, reason: 'the pending retry was cancelled');
      });
    });

    test('a stall between two bursts starts the count over', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.hadPlayed();
        r.dropByRefusedReplay();
        r.recovery.positionChanged(const Duration(milliseconds: 10400));
        r.elapse(_s(1)); // the retry is still 1 s away
        // Not enough time for the 4 s stall, so just a second burst.
        r.recovery.positionChanged(const Duration(milliseconds: 10440));
        expect(r.recoveries, isEmpty);
        r.elapse(_s(2));
        expect(r.reopens.length, 1);
      });
    });

    test('pending the offline wait, a stray event does not end it', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 11, 12, 12));
        var offline = 0;
        late final AudioRecovery recovery;
        recovery = AudioRecovery(
          reopen: () async => recovery.attemptFailed(),
          onGiveUp: () {},
          isReachable: () async => false,
          onOffline: () => offline++,
          now: clock.now,
        );
        recovery
          ..playingChanged(true)
          ..bufferingChanged(false)
          ..positionChanged(_s(5));
        recovery.schedule();
        async.elapse(_s(61));
        expect(offline, 1);
        expect(recovery.isWaitingForNetwork, isTrue);

        recovery.positionChanged(const Duration(milliseconds: 5400));
        expect(recovery.isWaitingForNetwork, isTrue);
        expect(recovery.isRecovering, isTrue);
      });
    });

    test('is reported to the service so it can be logged', () {
      fakeAsync((async) {
        var early = 0;
        final recovery = AudioRecovery(
          reopen: () async {},
          onGiveUp: () {},
          onEarlyProgress: () => early++,
        );
        recovery.schedule();
        recovery
          ..playingChanged(true)
          ..bufferingChanged(false)
          ..positionChanged(_s(5));
        expect(early, 1);
      });
    });
  });

  group('is this ended media a live stream (isLiveStream)', () {
    test('what the device showed: a duration at the end, none while playing',
        () {
      expect(
        isLiveStream(
          duration: _s(38),
          playedWithoutDuration: true,
        ),
        isTrue,
      );
    });

    test('a file had its duration while playing', () {
      expect(
        isLiveStream(duration: _s(212), playedWithoutDuration: false),
        isFalse,
      );
    });

    test('a demuxer that refuses seeks is live whatever the duration says', () {
      expect(isLiveStream(duration: _s(38), seekable: false), isTrue);
      expect(
        isLiveStream(
          duration: _s(38),
          seekable: false,
          playedWithoutDuration: false,
        ),
        isTrue,
      );
    });

    test('seekable alone does not make a file out of a stream with no length',
        () {
      expect(
        isLiveStream(
          duration: _s(38),
          seekable: true,
          playedWithoutDuration: true,
        ),
        isTrue,
      );
    });

    test('a stream that never played falls back to the duration at the end',
        () {
      expect(isLiveStream(duration: Duration.zero), isTrue);
      expect(isLiveStream(duration: _s(212)), isFalse);
      expect(isLiveStream(duration: _s(212), seekable: true), isFalse);
    });

    test('streamEndAction: a live stream with a duration at the end '
        'reconnects, it is not replayed', () {
      expect(
        streamEndAction(
          duration: _s(38),
          playedWithoutDuration: true,
          mayReconnect: true,
        ),
        StreamEndAction.reconnect,
      );
      expect(
        streamEndAction(
          duration: _s(38),
          seekable: false,
          mayReconnect: true,
        ),
        StreamEndAction.reconnect,
      );
      expect(
        streamEndAction(
          duration: _s(38),
          playedWithoutDuration: true,
          mayReconnect: false,
        ),
        StreamEndAction.ignore,
      );
      expect(
        streamEndAction(
          duration: _s(212),
          seekable: true,
          playedWithoutDuration: false,
          mayReconnect: true,
        ),
        StreamEndAction.replay,
      );
    });
  });

  group('StreamLengthEvidence', () {
    test('samples the duration at the first real position', () {
      final e = StreamLengthEvidence();
      expect(e.playedWithoutDuration, isNull);
      e.positionSeen(Duration.zero, Duration.zero);
      expect(e.playedWithoutDuration, isNull, reason: 'zero is the open');
      e.positionSeen(_ms(250), Duration.zero);
      expect(e.playedWithoutDuration, isTrue);
    });

    test('what mpv fills in when the stream ends changes nothing', () {
      final e = StreamLengthEvidence()
        ..positionSeen(_ms(250), Duration.zero)
        ..positionSeen(_s(38), _s(38));
      expect(e.playedWithoutDuration, isTrue);
    });

    test('a file already has its length', () {
      final e = StreamLengthEvidence()..positionSeen(_ms(250), _s(212));
      expect(e.playedWithoutDuration, isFalse);
    });

    test('reset forgets the stream', () {
      final e = StreamLengthEvidence()
        ..positionSeen(_ms(250), Duration.zero)
        ..reset();
      expect(e.playedWithoutDuration, isNull);
    });
  });
}
