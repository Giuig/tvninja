#!/usr/bin/env bash
# Emulator hook for integration_test/sound_mode_test.dart, started by the shared runner in
# the background before the test file ($1 = the file name; the environment carries OUT,
# DEVICE, PKG and LOGCAT). It starts before the test is even built and installed, so it
# waits for the test's E2E_SOUND_PLAYING marker first. The marker is read from the
# `flutter test` output the runner writes to $OUT/<file name>.txt: Dart's debugPrint reaches
# the flutter tool over the VM service, not logcat, so logcat would never show it.
#
# GATING (a failure fails the run), taken while the test is playing:
#   - dumpsys media_session: the app's session is playing (state=3) and its playback state
#     lists a custom action called Stop. From Android 13 the system media controls draw
#     only the playback state's custom actions, so this is what makes Stop visible there.
#   - dumpsys notification: the app's playback notification is posted.
#
# SESSION END, taken while the app process is still alive (the test keeps it alive after
# each stop, as on a phone): after a Stop, and again after a second start and stop, no
# playback session of the app may stay active, the playback service must be gone and
# have logged onDestroy, and a second start must leave exactly one session and no
# binding to the service. A failed check fails the run while STOP_GATING=1 (with 0 it is
# only recorded in the summary).
#
# MEDIA BUTTON, after the final stop: a play key and a headset-hook key sent while the app
# process is alive must not crash it (same pid afterwards, no crash of the app in logcat).
# Gated together with the session-end checks.
#
# NON-GATING, recorded in $OUT/summary_extra.md and the files next to it:
#   - the audio facts that bear on system equalizers (dumpsys audio, dumpsys
#     media.audio_flinger, effect-session broadcasts in logcat);
#   - an attempt to press Stop in the notification shade the way a user would.
#
# The same hook also serves integration_test/foreground_start_stop_test.dart (picked by $1,
# see foreground_start_stop_hook below): a start of the playback service followed at once
# by a stop must not crash the app. Its summary is appended to the sound mode one.
#
# And integration_test/lock_screen_test.dart (see lock_screen_hook below): a screen lock
# while a video plays must hand the stream over to sound, and the unlock must bring the
# picture back. Informational for now.
set -u

OUT=${OUT:?OUT is required}
DEVICE=${DEVICE:-emulator-5554}
PKG=${PKG:?PKG is required}
LOGCAT=${LOGCAT:-$OUT/logcat.txt}
MARKER=E2E_SOUND_PLAYING
TESTOUT="$OUT/${1:-sound_mode_test.dart}.txt"
WAIT_FOR_MARKER=${E2E_MARKER_TIMEOUT:-600}
EXTRA="$OUT/summary_extra.md"
# 1: a failed session-end check fails the run; 0: it is only recorded in the summary.
STOP_GATING=1

adb_() { adb -s "$DEVICE" "$@"; }

mkdir -p "$OUT"
# The first file's hook starts the summary; the hooks of later files append to it.
if [ "${1:-sound_mode_test.dart}" = "sound_mode_test.dart" ]; then : > "$EXTRA"; else touch "$EXTRA"; fi
failures=0
fail() {
  echo "GATING FAIL: $*"
  failures=$((failures + 1))
}
end_problems=0
end_check() {
  if [ "$STOP_GATING" -eq 1 ]; then
    fail "$*"
  else
    echo "NON-GATING: $*"
  fi
  end_problems=$((end_problems + 1))
}

# wait_for MARKER SECONDS: 0 once MARKER is in the test output, 1 on timeout or when the
# test has finished without printing it.
wait_for() {
  local m=$1 t=$2 i
  for i in $(seq 1 "$t"); do
    if grep -q "$m" "$TESTOUT" 2>/dev/null; then return 0; fi
    if grep -qE 'All tests passed|Some tests failed' "$TESTOUT" 2>/dev/null; then return 1; fi
    sleep 1
  done
  return 1
}

# capture_state LABEL: what Android holds for the app right now. Sets S_SESSIONS (media
# sessions of the app), S_ACTIVE (of those, active), S_PLAYING (in a playing state),
# S_STATES, S_RECORDS (running playback services), S_CONN (bindings to them),
# S_DESTROYS (onDestroy lines in logcat so far) and S_NOTIF (posted notifications).
capture_state() {
  local label=$1 f="$OUT/hook_state_$1"
  adb_ shell dumpsys media_session > "$f.media_session.raw" 2>&1 || true
  tr -d '\r' < "$f.media_session.raw" > "$f.media_session.txt"
  awk -v pkg="package=$PKG" '
    $0 ~ "^ *" pkg "$" { on = 1 }
    on { print }
    on && /queueTitle/ { on = 0; print "----" }
  ' "$f.media_session.txt" > "$f.blocks.txt"
  S_SESSIONS=$(grep -c '^----' "$f.blocks.txt")
  S_ACTIVE=$(grep -c 'active=true' "$f.blocks.txt")
  S_PLAYING=$(grep -cE 'state=PlaybackState \{state=(PLAYING\(3\)|3),' "$f.blocks.txt")
  S_STATES=$(grep -oE 'state=PlaybackState \{state=[^,]*' "$f.blocks.txt" | sed 's/.*state=//' | tr '\n' ' ')
  adb_ shell dumpsys activity services "$PKG" > "$f.services.raw" 2>&1 || true
  tr -d '\r' < "$f.services.raw" > "$f.services.txt"
  S_RECORDS=$(grep -c 'ServiceRecord{.*TvNinjaBackgroundService' "$f.services.txt")
  # Each binding shows up in three places in the dump; "All Connections" lists it once.
  S_CONN=$(awk '/All Connections:/ { on = 1; next } on && /ConnectionRecord\{/ { n++; next } on { on = 0 } END { print n + 0 }' "$f.services.txt")
  adb_ logcat -d > "$f.logcat.raw" 2>&1 || true
  S_DESTROYS=$(tr -d '\r' < "$f.logcat.raw" | grep -c 'TvNinjaService: onDestroy called')
  adb_ shell dumpsys notification --noredact > "$f.notification.raw" 2>&1 || true
  S_NOTIF=$(tr -d '\r' < "$f.notification.raw" | grep -cE "NotificationRecord.*pkg=$PKG")
  rm -f "$f.media_session.raw" "$f.services.raw" "$f.logcat.raw" "$f.notification.raw"
  STATE_LOG="${STATE_LOG}- $label: sessions=$S_SESSIONS active=$S_ACTIVE playing=$S_PLAYING states=[${S_STATES% }] playback services=$S_RECORDS bindings=$S_CONN onDestroy lines=$S_DESTROYS notifications=$S_NOTIF"$'\n'
}
STATE_LOG=""

# ---- foreground_start_stop_test.dart: the foreground service started and stopped at once -----
# Three tests, each with markers:
#   1. startBackground and stopBackground sent back to back from Dart, three rounds
#      (E2E_FGS_RACE_BEGIN .. E2E_FGS_RACE_DONE);
#   2. the same through NativeAudioService.startForegroundEarly and stop()
#      (E2E_EARLY_RACE_DONE);
#   3. an early start, then playback, then a stop (E2E_EARLY_PLAY_BEGIN, E2E_EARLY_PLAYING,
#      E2E_EARLY_STOPPED).
# The system kills an app whose startForegroundService call is not followed by
# startForeground in the service, and a stop that arrives first tears the service down in
# that window. Gated: the same app process from the first round to the end, no crash and no
# "did not then call startForeground" in logcat, nothing left running (no playback service,
# no session, no notification) after the rounds and after the final stop, and in test 3 a
# playing session with exactly one service start.

# wait_marker MARKER SECONDS: 0 once MARKER is in the test output; 1 on timeout, when the
# test has finished without it, or when the app process has been gone for three checks in a
# row (a crash: nothing more will be printed).
wait_marker() {
  local m=$1 t=$2 i gone=0
  for i in $(seq 1 "$t"); do
    if grep -q "$m" "$TESTOUT" 2>/dev/null; then return 0; fi
    if grep -qE 'All tests passed|Some tests failed' "$TESTOUT" 2>/dev/null; then return 1; fi
    if [ -n "${FGS_PID:-}" ] && [ -z "$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; then
      gone=$((gone + 1))
      if [ "$gone" -ge 3 ]; then return 1; fi
    else
      gone=0
    fi
    sleep 1
  done
  return 1
}

foreground_start_stop_hook() {
  local pid_after offset crash_buffer fatal_lines destroys deferred early_skip play_offset starts alive=1
  local slice_file="$OUT/hook_fgs_race_logcat.txt"
  echo "hook: waiting up to ${WAIT_FOR_MARKER}s for E2E_FGS_RACE_BEGIN in $TESTOUT"
  if ! wait_for E2E_FGS_RACE_BEGIN "$WAIT_FOR_MARKER"; then
    fail "marker E2E_FGS_RACE_BEGIN never appeared in $TESTOUT (the test never started)"
    {
      echo "### Foreground service started and stopped at once"
      echo
      echo "- **FAIL**: the test never started, so nothing was checked"
    } >> "$EXTRA"
    return 1
  fi
  echo "hook: marker seen"

  # What happens from here on is what this test is about: a crash buffer that is empty
  # now, the logcat file's current length, and the process id to compare against.
  adb_ logcat -b crash -c > /dev/null 2>&1 || true
  offset=$(wc -l < "$LOGCAT" 2>/dev/null || echo 0)
  FGS_PID=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  [ -n "$FGS_PID" ] || fail "the app process was not running when the rounds began, so nothing was checked"

  # Test 1: the channel calls back to back.
  if wait_marker E2E_FGS_RACE_DONE 150; then
    sleep 3
    capture_state "after the rounds"
    [ "$S_RECORDS" -eq 0 ] || fail "after the rounds: the playback service is still running ($S_RECORDS record(s))"
    [ "$S_ACTIVE" -eq 0 ] || fail "after the rounds: $S_ACTIVE media session(s) of $PKG still active (states: $S_STATES)"
    [ "$S_NOTIF" -eq 0 ] || fail "after the rounds: the playback notification is still posted"
  else
    fail "the test never reached E2E_FGS_RACE_DONE"
    alive=0
  fi

  # Test 2: the same through NativeAudioService.
  if [ "$alive" -eq 1 ]; then
    if wait_marker E2E_EARLY_RACE_DONE 120; then
      # Where test 3 starts in logcat: its service starts are counted from here. Test 2
      # made its last start seconds ago, and test 3 begins after a pause.
      play_offset=$(wc -l < "$LOGCAT" 2>/dev/null || echo 0)
      sleep 3
      capture_state "after the early-start rounds"
      [ "$S_RECORDS" -eq 0 ] || fail "after the early-start rounds: the playback service is still running ($S_RECORDS record(s))"
      [ "$S_ACTIVE" -eq 0 ] || fail "after the early-start rounds: $S_ACTIVE media session(s) of $PKG still active (states: $S_STATES)"
      [ "$S_NOTIF" -eq 0 ] || fail "after the early-start rounds: the playback notification is still posted"
    else
      fail "the test never reached E2E_EARLY_RACE_DONE"
      alive=0
    fi
  fi

  # Test 3: early start, playback, stop.
  if [ "$alive" -eq 1 ]; then
    if wait_marker E2E_EARLY_PLAY_BEGIN 60; then
      sleep 1
      if wait_marker E2E_EARLY_PLAYING 120; then
        sleep 3
        capture_state "early start, playing"
        [ "$S_SESSIONS" -eq 1 ] || fail "early start, playing: $S_SESSIONS media sessions of $PKG (want exactly 1)"
        [ "$S_PLAYING" -eq 1 ] || fail "early start, playing: the session is not playing (states: $S_STATES)"
        [ "$S_RECORDS" -eq 1 ] || fail "early start, playing: $S_RECORDS playback services (want 1)"
        [ "$S_NOTIF" -ge 1 ] || fail "early start, playing: no playback notification posted"
        starts=$(tail -n +"$((play_offset + 1))" "$LOGCAT" 2>/dev/null | tr -d '\r' | grep -c 'TvNinjaService: ACTION_START:')
        [ "$starts" -eq 1 ] || fail "early start, playing: the service was started $starts times (want exactly 1: play must not start it again)"
        if wait_marker E2E_EARLY_STOPPED 60; then
          sleep 4
          capture_state "after the early-start stop"
          [ "$S_RECORDS" -eq 0 ] || fail "after the early-start stop: the playback service is still running ($S_RECORDS record(s))"
          [ "$S_ACTIVE" -eq 0 ] || fail "after the early-start stop: $S_ACTIVE media session(s) of $PKG still active (states: $S_STATES)"
          [ "$S_NOTIF" -eq 0 ] || fail "after the early-start stop: the playback notification is still posted"
        else
          fail "the test never reached E2E_EARLY_STOPPED"
          alive=0
        fi
      else
        fail "the test never reached E2E_EARLY_PLAYING"
        alive=0
      fi
    else
      fail "the test never reached E2E_EARLY_PLAY_BEGIN"
      alive=0
    fi
  fi

  # Over the whole file: still the same process, and no crash anywhere.
  sleep 3
  pid_after=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  adb_ logcat -b crash -d 2>&1 | tr -d '\r' > "$OUT/hook_fgs_race_crash_buffer.txt" || true
  crash_buffer=$(grep -c 'FATAL EXCEPTION' "$OUT/hook_fgs_race_crash_buffer.txt")
  # The runner's logcat file, from where the rounds began (it streams continuously, so
  # give it a moment to catch up first).
  sleep 2
  tail -n +"$((offset + 1))" "$LOGCAT" 2>/dev/null | tr -d '\r' > "$slice_file" || true
  fatal_lines=$(grep -hE "FATAL EXCEPTION|ForegroundServiceDidNotStartInTimeException|did not then call Service.startForeground|Bringing down service while still waiting for start foreground" \
    "$slice_file" "$OUT/hook_fgs_race_crash_buffer.txt" | sort -u | head -8)
  if [ -n "$FGS_PID" ] && [ "$pid_after" != "$FGS_PID" ]; then
    fail "the app process changed or died (pid ${FGS_PID} -> ${pid_after:-none})"
  fi
  [ "$crash_buffer" -eq 0 ] || fail "$crash_buffer crash(es) of the app in the crash buffer"
  [ -z "$fatal_lines" ] || fail "logcat holds crash or startForeground lines: $(printf '%s' "$fatal_lines" | head -3 | tr '\n' '|')"
  destroys=$(grep -c 'TvNinjaService: onDestroy called' "$slice_file")
  deferred=$(grep -c 'A stop arrived while the start was pending, stopping now' "$slice_file")
  early_skip=$(grep -c 'Foreground service already started early' "$TESTOUT")

  {
    echo "### Foreground service started and stopped at once"
    echo
    if [ "$failures" -eq 0 ]; then echo "Gating: **pass**"; else echo "Gating: **FAIL** ($failures)"; fi
    echo
    echo '```'
    echo "app pid before=${FGS_PID:-none} after=${pid_after:-none}"
    echo "FATAL EXCEPTION lines in the crash buffer: $crash_buffer"
    echo "service onDestroy lines since the first round: $destroys"
    echo "stops the service held back until its start finished: $deferred"
    echo "play() skipped its own start (test output lines): $early_skip"
    printf '%s' "$STATE_LOG"
    if [ -n "$fatal_lines" ]; then echo "crash / startForeground lines:"; echo "$fatal_lines"; fi
    echo '```'
    echo
    echo "Evidence: e2e-out/hook_fgs_race_logcat.txt, hook_fgs_race_crash_buffer.txt, hook_state_*"
  } >> "$EXTRA"
  echo "hook: done, gating failures=$failures"
  [ "$failures" -eq 0 ]
}

# ---- lock_screen_test.dart: a screen lock while a video plays ----------------------------------
# The test opens the player page on a clip served by scripts/ci/serve_fixtures.py (started
# here, port LOCK_PORT) and logs E2E_VIDEO_PLAYING; this hook then does what a person does
# with the power key and reads what Android holds for the app.
#
# After KEYCODE_SLEEP, within 15 s (and still the same 3 s later): the app's media session
# is playing (state 3), the playback service is foreground, the app's audio players are
# exactly one OpenSL ES player (mpv, the sound mode) and no AudioTrack (ExoPlayer, the
# picture), and logcat holds no ForegroundServiceStartNotAllowedException, no "did not then
# call startForeground" and no FATAL EXCEPTION. After KEYCODE_WAKEUP and `wm
# dismiss-keyguard`, within 15 s: no active session of the app, the playback service gone
# (onDestroy logged), exactly one AudioTrack and no OpenSL player, and the same app process
# at the end.
#
# INFORMATIONAL for now (LOCK_GATING=0): a failed check is written to the summary and to the
# hook's output and does not fail the run. It cannot go in the shim's informational-files,
# because the shared runner starts the hook only for e2e-files. A crash of the app still
# fails the job, since the runner scans the whole logcat for FATAL EXCEPTION.
#
# Promoting it to gating needs two green runs and a local video source; the clip is local.
LOCK_GATING=0
LOCK_PORT=8098
LOCK_PROBLEMS=0
LOCK_PROBLEM_LOG=""
lock_problem() {
  LOCK_PROBLEMS=$((LOCK_PROBLEMS + 1))
  LOCK_PROBLEM_LOG="${LOCK_PROBLEM_LOG}- $*"$'\n'
  echo "LOCK CHECK FAILED: $*"
}

# lock_snapshot LABEL: capture_state plus the two things only this test asks about. Sets
# L_FG (the playback service is a foreground service) and L_OPENSL / L_TRACK (the app's
# OpenSL ES players and AudioTracks in dumpsys audio, whatever their state).
lock_snapshot() {
  local f="$OUT/hook_state_$1"
  capture_state "$1"
  L_FG=$(grep -c 'isForeground=true' "$f.services.txt")
  adb_ shell dumpsys audio 2>&1 | tr -d '\r' | grep -E "u/pid:$APP_UID/" | sed 's/^ *//' > "$f.players.txt" || true
  L_OPENSL=$(grep -c 'type:OpenSL ES' "$f.players.txt")
  L_TRACK=$(grep -c 'type:android.media.AudioTrack' "$f.players.txt")
  STATE_LOG="${STATE_LOG%$'\n'}; foreground=$L_FG OpenSL players=$L_OPENSL AudioTracks=$L_TRACK"$'\n'
}
lock_snapshot_line() {
  echo "sessions=$S_SESSIONS active=$S_ACTIVE playing=$S_PLAYING states=[${S_STATES% }] playback services=$S_RECORDS foreground=$L_FG OpenSL players=$L_OPENSL AudioTracks=$L_TRACK notifications=$S_NOTIF"
}
lock_sound_ok() { [ "$S_PLAYING" -eq 1 ] && [ "$L_FG" -ge 1 ] && [ "$L_OPENSL" -eq 1 ] && [ "$L_TRACK" -eq 0 ]; }
lock_video_ok() { [ "$S_ACTIVE" -eq 0 ] && [ "$S_RECORDS" -eq 0 ] && [ "$L_OPENSL" -eq 0 ] && [ "$L_TRACK" -eq 1 ]; }

# lock_poll LABEL CHECK SECONDS: snapshots every second until CHECK holds or SECONDS pass.
# Sets POLL_OK (1/0) and POLL_AT (seconds until it held). The polls are left out of the
# state log; the caller takes the snapshot that is reported.
lock_poll() {
  local label=$1 check=$2 limit=$3 start=$SECONDS keep
  POLL_OK=0
  POLL_AT=""
  while :; do
    keep=$STATE_LOG
    lock_snapshot "$label"
    STATE_LOG=$keep
    if "$check"; then POLL_OK=1; POLL_AT=$((SECONDS - start)); break; fi
    [ $((SECONDS - start)) -ge "$limit" ] && break
    sleep 1
  done
}

# lock_permission_watch: a reinstalled test app has lost its notification grant, and the app
# asks for it when it starts, so a permission dialog can sit over the page. While it does,
# the app is `inactive` and a wake would show the dialog again instead of the app. Once a
# second: if the permission dialog has the focus, grant the permission (so it does not
# return) and press back if the dialog is still there. Each action is written to
# hook_lock_permission_watch.txt. Runs in the background; the hook's exit trap stops it.
lock_permission_watch() {
  local focus
  while :; do
    focus=$(adb_ shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 'mCurrentFocus')
    case "$focus" in
      *GrantPermissionsActivity*)
        adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS > /dev/null 2>&1 || true
        sleep 1
        focus=$(adb_ shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 'mCurrentFocus')
        case "$focus" in
          *GrantPermissionsActivity*)
            adb_ shell input keyevent KEYCODE_BACK > /dev/null 2>&1 || true
            echo "$(date +%T) permission dialog on top: granted POST_NOTIFICATIONS, still there, pressed back" >> "$OUT/hook_lock_permission_watch.txt" ;;
          *)
            echo "$(date +%T) permission dialog on top: granted POST_NOTIFICATIONS, it closed by itself" >> "$OUT/hook_lock_permission_watch.txt" ;;
        esac ;;
    esac
    sleep 1
  done
}

lock_screen_hook() {
  local pid_before pid_after offset slice="$OUT/hook_lock_logcat.txt" fatal destroys
  SLEEP_AT=""
  WAKE_AT=""
  LOCK_PID_LINE=""
  LOCK_FATAL=""
  python3 scripts/ci/serve_fixtures.py integration_test/fixtures "$LOCK_PORT" "$OUT/fixture_server.log" > "$OUT/fixture_server.out" 2>&1 &
  FIX_PID=$!
  lock_permission_watch &
  WATCH_PID=$!
  trap 'kill "$FIX_PID" "$WATCH_PID" 2>/dev/null || true' EXIT
  echo "hook: fixture server pid=$FIX_PID on 127.0.0.1:$LOCK_PORT; waiting up to ${WAIT_FOR_MARKER}s for E2E_VIDEO_PLAYING in $TESTOUT"

  if ! wait_for E2E_VIDEO_PLAYING "$WAIT_FOR_MARKER"; then
    if grep -q E2E_VIDEO_FAILED "$TESTOUT" 2>/dev/null; then
      lock_problem "the clip never played in the app ($(grep -m1 E2E_VIDEO_FAILED "$TESTOUT")), so nothing was checked"
    else
      lock_problem "marker E2E_VIDEO_PLAYING never appeared in $TESTOUT (the test never started), so nothing was checked"
    fi
    lock_summary
    return 0
  fi
  echo "hook: video playing"
  sleep 2
  APP_UID=$(adb_ shell pm list packages -U "$PKG" 2>/dev/null | tr -d '\r' | grep -m1 "package:$PKG " | sed 's/.*uid://')
  [ -n "$APP_UID" ] || lock_problem "could not read the app's uid, so its audio players cannot be counted"

  lock_snapshot "video playing, before the lock"
  if ! { [ "$S_ACTIVE" -eq 0 ] && [ "$S_RECORDS" -eq 0 ] && [ "$L_OPENSL" -eq 0 ] && [ "$L_TRACK" -eq 1 ]; }; then
    lock_problem "before the lock the picture was not what a lock test starts from (want no session, no service, 1 AudioTrack, 0 OpenSL): $(lock_snapshot_line)"
  fi

  adb_ logcat -b crash -c > /dev/null 2>&1 || true
  offset=$(wc -l < "$LOGCAT" 2>/dev/null || echo 0)
  pid_before=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  [ -n "$pid_before" ] || lock_problem "the app process was not running when the lock began"

  # ---- SLEEP ----
  echo "hook: KEYCODE_SLEEP"
  adb_ shell input keyevent KEYCODE_SLEEP
  lock_poll "after sleep, polling" lock_sound_ok 15
  SLEEP_AT=$POLL_AT
  if [ "$POLL_OK" -eq 1 ]; then
    # It must still hold a moment later: a handover that is only passing through does not count.
    sleep 3
    lock_snapshot "after sleep"
    lock_sound_ok || lock_problem "after sleep the sound state did not hold: it was right after ${SLEEP_AT}s and wrong 3 s later: $(lock_snapshot_line)"
  else
    lock_snapshot "after sleep"
    lock_problem "within 15 s of sleep the app was not playing as sound (want session playing, foreground service, 1 OpenSL, 0 AudioTrack): $(lock_snapshot_line)"
  fi
  adb_ shell dumpsys power 2>&1 | tr -d '\r' | grep -m1 'mWakefulness=' > "$OUT/hook_lock_wakefulness_asleep.txt" || true

  # ---- WAKEUP ----
  echo "hook: KEYCODE_WAKEUP + dismiss-keyguard"
  adb_ shell input keyevent KEYCODE_WAKEUP
  adb_ shell wm dismiss-keyguard > /dev/null 2>&1 || true
  lock_poll "after wake, polling" lock_video_ok 15
  WAKE_AT=$POLL_AT
  if [ "$POLL_OK" -eq 1 ]; then
    sleep 3
    lock_snapshot "after wake"
    lock_video_ok || lock_problem "after wake the video state did not hold: it was right after ${WAKE_AT}s and wrong 3 s later: $(lock_snapshot_line)"
  else
    lock_snapshot "after wake"
    lock_problem "within 15 s of wake the app was not back on video (want no active session, no service, 0 OpenSL, 1 AudioTrack): $(lock_snapshot_line)"
  fi
  adb_ shell dumpsys power 2>&1 | tr -d '\r' | grep -m1 'mWakefulness=' > "$OUT/hook_lock_wakefulness_awake.txt" || true

  # ---- logcat over the whole lock, and the same process ----
  wait_for E2E_LOCK_DONE 90 || true
  sleep 3
  pid_after=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  adb_ logcat -b crash -d 2>&1 | tr -d '\r' > "$OUT/hook_lock_crash_buffer.txt" || true
  tail -n +"$((offset + 1))" "$LOGCAT" 2>/dev/null | tr -d '\r' > "$slice" || true
  fatal=$(grep -hE "FATAL EXCEPTION|ForegroundServiceStartNotAllowedException|ForegroundServiceDidNotStartInTimeException|did not then call Service.startForeground|Bringing down service while still waiting for start foreground" \
    "$slice" "$OUT/hook_lock_crash_buffer.txt" | sort -u | head -8)
  [ -z "$fatal" ] || lock_problem "logcat holds crash or foreground-start lines: $(printf '%s' "$fatal" | head -3 | tr '\n' '|')"
  destroys=$(grep -c 'TvNinjaService: onDestroy called' "$slice")
  [ "$destroys" -ge 1 ] || lock_problem "the playback service never logged onDestroy after the lock began"
  if [ -n "$pid_before" ] && [ "$pid_after" != "$pid_before" ]; then
    lock_problem "the app process changed or died (pid ${pid_before} -> ${pid_after:-none})"
  fi
  LOCK_PID_LINE="app pid before=${pid_before:-none} after=${pid_after:-none}; service onDestroy lines since the lock=$destroys"
  LOCK_FATAL=$fatal
  lock_summary
  return 0
}

# lock_summary: the section of the step summary, and LOCK_EXIT, the hook's exit status.
lock_summary() {
  local mode=informational
  [ "$LOCK_GATING" -eq 1 ] && mode=gating
  {
    echo "### Lock screen hook ($mode)"
    echo
    if [ "$LOCK_PROBLEMS" -eq 0 ]; then echo "Result: **all checks passed**"; else echo "Result: **$LOCK_PROBLEMS check(s) failed**"; fi
    echo
    if [ -n "$LOCK_PROBLEM_LOG" ]; then printf '%s\n' "$LOCK_PROBLEM_LOG"; fi
    echo '```'
    echo "sound within: ${SLEEP_AT:-n/a}s of sleep (limit 15); video back within: ${WAKE_AT:-n/a}s of wake (limit 15)"
    echo "${LOCK_PID_LINE:-(no process line: the lock was not reached)}"
    printf '%s' "$STATE_LOG"
    echo "wakefulness while locked: $(cat "$OUT/hook_lock_wakefulness_asleep.txt" 2>/dev/null)"
    echo "wakefulness after wake:   $(cat "$OUT/hook_lock_wakefulness_awake.txt" 2>/dev/null)"
    echo "the app's own view (test output):"
    grep -E 'E2E_LIFECYCLE|E2E_VIDEO_AFTER_UNLOCK|E2E_VIDEO_FAILED' "$TESTOUT" 2>/dev/null || echo "(none)"
    echo "the app's players, while locked:"
    cat "$OUT/hook_state_after sleep.players.txt" 2>/dev/null || echo "(none)"
    echo "the app's players, after the wake:"
    cat "$OUT/hook_state_after wake.players.txt" 2>/dev/null || echo "(none)"
    if [ -n "$LOCK_FATAL" ]; then echo "crash / foreground-start lines:"; echo "$LOCK_FATAL"; fi
    echo "permission dialog handling: $(cat "$OUT/hook_lock_permission_watch.txt" 2>/dev/null | tr '\n' '|')"
    echo "clip requests served: $(grep -c 'GET /lock_clip.mp4' "$OUT/fixture_server.log" 2>/dev/null)"
    echo '```'
    echo
    echo "Evidence: e2e-out/hook_state_*, hook_lock_*, fixture_server.log"
  } >> "$EXTRA"
  echo "hook: done, lock check problems=$LOCK_PROBLEMS ($mode)"
  if [ "$LOCK_GATING" -eq 1 ] && [ "$LOCK_PROBLEMS" -gt 0 ]; then failures=$((failures + LOCK_PROBLEMS)); fi
  if [ "$failures" -eq 0 ]; then LOCK_EXIT=0; else LOCK_EXIT=1; fi
}

case "${1:-sound_mode_test.dart}" in
  lock_screen_test.dart)
    LOCK_EXIT=0
    lock_screen_hook
    exit "$LOCK_EXIT"
    ;;
  foreground_start_stop_test.dart)
    foreground_start_stop_hook
    exit $?
    ;;
esac

echo "hook: waiting up to ${WAIT_FOR_MARKER}s for $MARKER in $TESTOUT"
seen=0
for _ in $(seq 1 "$WAIT_FOR_MARKER"); do
  if [ -f "$TESTOUT" ] && grep -q "$MARKER" "$TESTOUT"; then seen=1; break; fi
  sleep 1
done
if [ "$seen" -ne 1 ]; then
  echo "GATING FAIL: marker $MARKER never appeared in $TESTOUT (the test never reached playback)"
  {
    echo "### sound mode hook"
    echo "- **FAIL**: the test never reached playback, so nothing was checked"
  } >> "$EXTRA"
  exit 1
fi
echo "hook: marker seen"

# ---- GATING 1: the media session -------------------------------------------------------
# Retried for a few seconds: the session state follows the Dart side by a moment.
session_ok=0
for _ in $(seq 1 10); do
  adb_ shell dumpsys media_session > "$OUT/hook_media_session.txt" 2>&1 || true
  # The block of this app's session: from its `package=` line to the session's queueTitle.
  awk -v pkg="package=$PKG" '
    $0 ~ "^ *" pkg "$" { on = 1 }
    on { print }
    on && /queueTitle/ { exit }
  ' "$OUT/hook_media_session.txt" | tr -d '\r' > "$OUT/hook_session_block.txt"
  # Android 9 prints state=3, Android 14 prints state=PLAYING(3).
  if grep -qE 'state=PlaybackState \{state=(PLAYING\()?3\)?,' "$OUT/hook_session_block.txt"; then
    session_ok=1
    break
  fi
  sleep 2
done
session_state=$(grep -m1 -o 'state=PlaybackState {[^}]*}' "$OUT/hook_session_block.txt")
if [ ! -s "$OUT/hook_session_block.txt" ]; then
  fail "no media session for $PKG in dumpsys media_session"
elif [ "$session_ok" -ne 1 ]; then
  fail "media session of $PKG is not playing (state=3): ${session_state:-no state line}"
fi
stop_action=$(grep -m1 -o "custom actions=\[[^]]*\]" "$OUT/hook_session_block.txt")
case "$stop_action" in
  *Stop*) : ;;
  *) fail "the media session has no custom action named Stop (saw: ${stop_action:-no custom actions line})" ;;
esac

# ---- GATING 2: the notification --------------------------------------------------------
adb_ shell dumpsys notification --noredact > "$OUT/hook_notification.txt" 2>&1 || true
tr -d '\r' < "$OUT/hook_notification.txt" > "$OUT/hook_notification_clean.txt"
if ! grep -qE "NotificationRecord.*pkg=$PKG" "$OUT/hook_notification_clean.txt"; then
  fail "no posted notification for $PKG in dumpsys notification"
fi
notification_actions=$(grep -A12 -E "NotificationRecord.*pkg=$PKG" "$OUT/hook_notification_clean.txt" \
  | grep -E 'actions=|^ *\[[0-9]\]' | head -6)

# ---- EQ evidence (non-gating) -----------------------------------------------------------
uid=$(adb_ shell pm list packages -U "$PKG" 2>/dev/null | tr -d '\r' | grep -m1 "package:$PKG " | sed 's/.*uid://')
pid=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
adb_ shell dumpsys audio > "$OUT/hook_dumpsys_audio.txt" 2>&1 || true
adb_ shell dumpsys media.audio_flinger > "$OUT/hook_audio_flinger.txt" 2>&1 || true
tr -d '\r' < "$OUT/hook_dumpsys_audio.txt" > "$OUT/hook_dumpsys_audio_clean.txt"
tr -d '\r' < "$OUT/hook_audio_flinger.txt" > "$OUT/hook_audio_flinger_clean.txt"

audio_players=""
if [ -n "$uid" ]; then
  audio_players=$(grep -E "u/pid:$uid/" "$OUT/hook_dumpsys_audio_clean.txt" | sed 's/^ *//' | sort -u)
fi

# Per output thread that carries one of the app's tracks: the thread's header line, then
# its track lines for the app's pid. Flags (FAST, MMAP, deep buffer) are in those lines.
flinger_threads=""
if [ -n "$pid" ]; then
  flinger_threads=$(awk -v pid="$pid" '
    /^(Output|Input) thread / { header = $0; shown = 0 }
    /^Output thread / || /^Input thread / { next }
    {
      n = split($0, f, " ")
      for (i = 1; i <= n; i++) if (f[i] == pid) {
        if (!shown) { print header; shown = 1 }
        print "  " $0
        break
      }
    }
  ' "$OUT/hook_audio_flinger_clean.txt" | head -40)
fi
flinger_flags=$(grep -iE 'Output thread|Thread name|Standby|Output flags|HAL (frame|format)|FastMixer|Effect chain|no effect' \
  "$OUT/hook_audio_flinger_clean.txt" | sed 's/^ *//' | head -25)
effect_lines=$(grep -E 'OPEN_AUDIO_EFFECT_CONTROL_SESSION|CLOSE_AUDIO_EFFECT_CONTROL_SESSION' "$LOGCAT" | head -10)
effect_count=$(grep -cE 'OPEN_AUDIO_EFFECT_CONTROL_SESSION' "$LOGCAT")

# ---- Non-gating: press Stop in the shade like a user ---------------------------------
tap_log=""
tap_note() { tap_log="${tap_log}- $*"$'\n'; }
find_stop() {
  python3 -I - "$1" <<'PY'
import re, sys
import xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:
    print("ERR parse " + str(e)); sys.exit(0)
for node in root.iter("node"):
    desc = (node.get("content-desc") or "").strip()
    if desc.lower() == "stop":
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds") or "")
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            print("%d %d" % ((x1 + x2) // 2, (y1 + y2) // 2)); sys.exit(0)
print("NONE")
PY
}

# What SystemUI itself knows about media, to explain a shade without a media control.
adb_ shell dumpsys activity service com.android.systemui/.SystemUIService > "$OUT/hook_systemui.txt" 2>&1 || true
systemui_media=$(tr -d '\r' < "$OUT/hook_systemui.txt" | grep -iE "$PKG|media.*(player|control|data)" | sed 's/^ *//' | cut -c1-200 | head -25)

stop_before=$(grep -c 'E2E_STOP_REQUESTED' "$TESTOUT")
tapped=0
for mode in expand-notifications expand-settings; do
  adb_ shell cmd statusbar "$mode" > /dev/null 2>&1 || true
  sleep 5
  adb_ shell uiautomator dump /sdcard/shade_$mode.xml > "$OUT/hook_uiautomator_$mode.txt" 2>&1 || true
  adb_ pull /sdcard/shade_$mode.xml "$OUT/hook_shade_$mode.xml" > /dev/null 2>&1 || true
  if [ ! -s "$OUT/hook_shade_$mode.xml" ]; then
    tap_note "$mode: no uiautomator dump ($(tr -d '\r' < "$OUT/hook_uiautomator_$mode.txt" | head -1))"
    continue
  fi
  xy=$(find_stop "$OUT/hook_shade_$mode.xml")
  case "$xy" in
    NONE|ERR*)
      tap_note "$mode: no node with content-desc \"Stop\" in the dump (${xy})"
      ;;
    *)
      tap_note "$mode: found Stop at $xy, tapping"
      adb_ shell input tap $xy > /dev/null 2>&1 || true
      tapped=1
      break
      ;;
  esac
done
if [ "$tapped" -eq 1 ]; then
  sleep 4
  stop_after=$(grep -c 'E2E_STOP_REQUESTED' "$TESTOUT")
  if [ "$stop_after" -gt "$stop_before" ]; then
    tap_note "RESULT: the tap reached the app (E2E_STOP_REQUESTED in the test output)"
  else
    tap_note "RESULT: the tap did not reach the app (no E2E_STOP_REQUESTED)"
  fi
  oncustom=$(grep -c 'MediaSession onCustomAction' "$LOGCAT")
  tap_note "logcat 'MediaSession onCustomAction' lines: $oncustom"
  adb_ shell dumpsys media_session > "$OUT/hook_media_session_after_tap.txt" 2>&1 || true
  if grep -q "package=$PKG" "$OUT/hook_media_session_after_tap.txt"; then
    tap_note "after the tap: a session for $PKG still exists in dumpsys media_session"
  else
    tap_note "after the tap: no session for $PKG in dumpsys media_session (playback stopped)"
  fi
else
  tap_note "RESULT: Stop was not found in the shade, so no tap was made"
fi
adb_ shell cmd statusbar collapse > /dev/null 2>&1 || true

# ---- Session end (gated by STOP_GATING) ----------------------------------------------
# Stop 1: from the shade tap when it worked, else the test stops itself after its hold.
if wait_for E2E_STOPPED_1 90; then
  sleep 4
  capture_state "after stop 1"
  [ "$S_ACTIVE" -eq 0 ] || end_check "after stop 1: $S_ACTIVE media session(s) of $PKG still active (states: $S_STATES)"
  [ "$S_PLAYING" -eq 0 ] || end_check "after stop 1: a media session of $PKG is still playing"
  [ "$S_RECORDS" -eq 0 ] || end_check "after stop 1: the playback service is still running ($S_RECORDS record(s), $S_CONN binding(s))"
  [ "$S_DESTROYS" -ge 1 ] || end_check "after stop 1: the service never logged onDestroy"
  [ "$S_NOTIF" -eq 0 ] || end_check "after stop 1: the playback notification is still posted"
else
  end_check "the test never reached E2E_STOPPED_1, so the state after stop 1 was not checked"
fi

# Start again: exactly one session, no leftover binding.
if wait_for E2E_CYCLE_PLAYING 90; then
  sleep 3
  capture_state "second start"
  [ "$S_SESSIONS" -eq 1 ] || end_check "second start: $S_SESSIONS media sessions of $PKG (want exactly 1)"
  [ "$S_PLAYING" -eq 1 ] || end_check "second start: the session is not playing (states: $S_STATES)"
  [ "$S_RECORDS" -eq 1 ] || end_check "second start: $S_RECORDS playback services (want 1)"
  [ "$S_CONN" -eq 0 ] || end_check "second start: $S_CONN binding(s) to the playback service (want none)"
  [ "$S_NOTIF" -ge 1 ] || end_check "second start: no playback notification posted"
else
  end_check "the test never reached E2E_CYCLE_PLAYING, so the second start was not checked"
fi

# Stop 2, from the test.
if wait_for E2E_STOPPED_2 90; then
  sleep 4
  capture_state "after stop 2"
  [ "$S_ACTIVE" -eq 0 ] || end_check "after stop 2: $S_ACTIVE media session(s) of $PKG still active (states: $S_STATES)"
  [ "$S_PLAYING" -eq 0 ] || end_check "after stop 2: a media session of $PKG is still playing"
  [ "$S_RECORDS" -eq 0 ] || end_check "after stop 2: the playback service is still running ($S_RECORDS record(s), $S_CONN binding(s))"
  [ "$S_DESTROYS" -ge 2 ] || end_check "after stop 2: onDestroy logged $S_DESTROYS time(s), want 2"
  [ "$S_NOTIF" -eq 0 ] || end_check "after stop 2: the playback notification is still posted"
else
  end_check "the test never reached E2E_STOPPED_2, so the state after stop 2 was not checked"
fi

# ---- Media button after the final stop (gated with the session-end checks) -------------------
# A headset or Bluetooth Play press once the session is gone must not crash the app. The
# system sends such a key to the receiver the last session registered; the androidx
# MediaButtonReceiver threw IllegalStateException there because no service handles
# MEDIA_BUTTON. The app has no such receiver any more, so the key goes nowhere. Sent while
# the app process is still alive (the test keeps it up 25 s after the stop), with a plain
# play and a headset hook a few seconds apart.
# The keys go through the media session service (`cmd media_session dispatch`), the path a
# Bluetooth headset takes. `input keyevent` is only the fallback for an image without that
# command: it injects through the window, and on the emulator the app window had no focus
# after the shade, so the injected key waited 5 s and raised an ANR that has nothing to do
# with the receiver.
# The dispatch command's own output and exit status are kept in DISPATCH_LOG (shown in the
# summary), so a dispatch that never reached the media session service cannot hide behind
# "no key events logged".
DISPATCH_LOG=""
send_key() { # $1 = cmd media_session name, $2 = keycode for the fallback
  local out rc how=dispatch
  out=$(adb_ shell cmd media_session dispatch "$1" 2>&1); rc=$?
  out=$(printf '%s' "$out" | tr -d '\r')
  case "$out" in
    *"No shell command"*|*"nknown command"*|*"rror"*)
      how="dispatch failed, fell back to input keyevent $2"
      adb_ shell input keyevent "$2" > /dev/null 2>&1 || true ;;
  esac
  DISPATCH_LOG="${DISPATCH_LOG}cmd media_session dispatch $1: exit=$rc via=$how output=[$(printf '%s' "$out" | head -c 300 | tr '\n' ' ')]"$'\n'
}
KEY_LOG=""
if grep -q 'E2E_STOPPED_2' "$TESTOUT" 2>/dev/null; then
  pid_before=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  send_key play KEYCODE_MEDIA_PLAY
  sleep 3
  send_key headsethook KEYCODE_HEADSETHOOK
  sleep 3
  pid_after=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  adb_ logcat -d 2>&1 | tr -d '\r' > "$OUT/hook_logcat_after_keys.txt" || true
  # The runner's logcat file, and the device's own buffer, whichever has the crash.
  crash_lines=$(cat "$OUT/hook_logcat_after_keys.txt" "$LOGCAT" 2>/dev/null \
    | grep -E "Process: $PKG,|Could not find any Service that handles" | sort -u | head -6)
  key_lines=$(grep -cE 'Sending KeyEvent .*(KEYCODE_MEDIA_PLAY|KEYCODE_HEADSETHOOK)' "$OUT/hook_logcat_after_keys.txt")
  KEY_LOG="- pid before=${pid_before:-none} after=${pid_after:-none}; key events logged by the media session service=$key_lines; crash lines=$(printf '%s' "$crash_lines" | grep -c .)"$'\n'
  KEY_LOG="${KEY_LOG}${DISPATCH_LOG}"
  KEY_LOG="${KEY_LOG}- reading: with the fix there is no media button receiver, so key_lines=0 (no 'Sending KeyEvent' line) is EXPECTED and is not a failure; the verdict is the same pid before and after and no crash lines. Without the fix the key is expected to reach the old receiver and the app to die with 'Could not find any Service that handles android.intent.action.MEDIA_BUTTON'."$'\n'
  if [ -z "$pid_before" ]; then
    end_check "media button: the app process was already gone before the key was sent, so nothing was checked"
  elif [ "$pid_after" != "$pid_before" ]; then
    end_check "media button after the final stop: the app process changed or died (pid ${pid_before} -> ${pid_after:-none})"
  fi
  if [ -n "$crash_lines" ]; then
    end_check "media button after the final stop: crash in logcat: $(printf '%s' "$crash_lines" | head -3 | tr '\n' '|')"
  fi
else
  end_check "the test never reached E2E_STOPPED_2, so the media button was not tried"
fi

# ---- summary_extra.md ----------------------------------------------------------------
{
  echo "### Sound mode hook"
  echo
  if [ "$failures" -eq 0 ]; then echo "Gating: **pass**"; else echo "Gating: **FAIL** ($failures)"; fi
  echo
  echo '```'
  echo "session state:  ${session_state:-none}"
  echo "stop action:    ${stop_action:-none}"
  echo "notification:   $(grep -qE "NotificationRecord.*pkg=$PKG" "$OUT/hook_notification_clean.txt" && echo posted || echo MISSING)"
  [ -n "$notification_actions" ] && echo "$notification_actions"
  echo '```'
  echo
  echo "#### Stop pressed in the shade (non-gating)"
  echo
  printf '%s' "$tap_log"
  echo
  if [ "$STOP_GATING" -eq 1 ]; then mode=gating; else mode=non-gating; fi
  echo "#### Session end ($mode): $end_problems problem(s)"
  echo
  echo "Taken while the app process is alive. sessions = media sessions of the app in dumpsys media_session; bindings = the service's 'All Connections' entries in dumpsys activity services."
  echo '```'
  printf '%s' "$STATE_LOG"
  echo '```'
  echo
  echo "Media button after the final stop (play, then headset hook; $mode):"
  echo '```'
  printf '%s' "${KEY_LOG:-(not sent)}"
  echo '```'
  echo
  echo "SystemUI lines about this app or media controls:"
  echo '```'
  echo "${systemui_media:-(none)}"
  echo '```'
  echo
  echo "#### Audio facts for the equalizer question (non-gating, uid=${uid:-?} pid=${pid:-?})"
  echo
  echo "dumpsys audio, the app's players:"
  echo '```'
  echo "${audio_players:-(none found)}"
  echo '```'
  echo "dumpsys media.audio_flinger, threads carrying the app's tracks:"
  echo '```'
  echo "${flinger_threads:-(none found)}"
  echo '```'
  echo "dumpsys media.audio_flinger, thread and effect-chain lines:"
  echo '```'
  echo "${flinger_flags:-(none found)}"
  echo '```'
  echo "effect-control-session broadcasts in logcat: $effect_count"
  if [ -n "$effect_lines" ]; then
    echo '```'
    echo "$effect_lines"
    echo '```'
  fi
  echo
  echo "Full dumps: e2e-out/hook_dumpsys_audio.txt, hook_audio_flinger.txt, hook_media_session.txt, hook_notification.txt, hook_shade_*.xml, hook_state_*"
} >> "$EXTRA"

echo "hook: done, gating failures=$failures"
[ "$failures" -eq 0 ]
