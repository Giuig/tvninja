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
: > "$EXTRA"
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

# ---- Media button after the final stop (gated by KEY_GATING) -------------------------------
# A headset or Bluetooth Play press once the session is gone must not crash the app. The
# system sends such a key to the receiver the last session registered; the androidx
# MediaButtonReceiver threw IllegalStateException there because no service handles
# MEDIA_BUTTON. The app has no such receiver any more, so the key goes nowhere. Sent while
# the app process is still alive (the test keeps it up 25 s after the stop), with a plain
# play and a headset hook a few seconds apart.
KEY_LOG=""
if grep -q 'E2E_STOPPED_2' "$TESTOUT" 2>/dev/null; then
  pid_before=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  adb_ shell input keyevent KEYCODE_MEDIA_PLAY > /dev/null 2>&1 || true
  sleep 3
  adb_ shell input keyevent KEYCODE_HEADSETHOOK > /dev/null 2>&1 || true
  sleep 3
  pid_after=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  adb_ logcat -d 2>&1 | tr -d '\r' > "$OUT/hook_logcat_after_keys.txt" || true
  # The runner's logcat file, and the device's own buffer, whichever has the crash.
  crash_lines=$(cat "$OUT/hook_logcat_after_keys.txt" "$LOGCAT" 2>/dev/null \
    | grep -E "Process: $PKG,|Could not find any Service that handles" | sort -u | head -6)
  key_lines=$(grep -cE 'Sending KeyEvent .*(KEYCODE_MEDIA_PLAY|KEYCODE_HEADSETHOOK)' "$OUT/hook_logcat_after_keys.txt")
  KEY_LOG="- pid before=${pid_before:-none} after=${pid_after:-none}; key events logged by the media session service=$key_lines; crash lines=$(printf '%s' "$crash_lines" | grep -c .)"$'\n'
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
