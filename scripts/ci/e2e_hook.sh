#!/usr/bin/env bash
# Emulator hook for integration_test/sound_mode_test.dart, started by the shared runner in
# the background before the test file ($1 = the file name; the environment carries OUT,
# DEVICE, PKG and LOGCAT). It starts before the test is even built and installed, so it
# waits for the test's E2E_SOUND_PLAYING marker in logcat first.
#
# GATING (a failure fails the run), taken while the test is playing:
#   - dumpsys media_session: the app's session is playing (state=3) and its playback state
#     lists a custom action called Stop. From Android 13 the system media controls draw
#     only the playback state's custom actions, so this is what makes Stop visible there.
#   - dumpsys notification: the app's playback notification is posted.
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
WAIT_FOR_MARKER=${E2E_MARKER_TIMEOUT:-600}
EXTRA="$OUT/summary_extra.md"

adb_() { adb -s "$DEVICE" "$@"; }

mkdir -p "$OUT"
: > "$EXTRA"
failures=0
fail() {
  echo "GATING FAIL: $*"
  failures=$((failures + 1))
}

echo "hook: waiting up to ${WAIT_FOR_MARKER}s for $MARKER in $LOGCAT"
seen=0
for _ in $(seq 1 "$WAIT_FOR_MARKER"); do
  if [ -f "$LOGCAT" ] && grep -q "$MARKER" "$LOGCAT"; then seen=1; break; fi
  sleep 1
done
if [ "$seen" -ne 1 ]; then
  echo "GATING FAIL: marker $MARKER never appeared in logcat (the test never reached playback)"
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
  if grep -q 'state=PlaybackState {state=3,' "$OUT/hook_session_block.txt"; then
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

stop_before=$(grep -c 'E2E_STOP_REQUESTED' "$LOGCAT")
tapped=0
for mode in expand-notifications expand-settings; do
  adb_ shell cmd statusbar "$mode" > /dev/null 2>&1 || true
  sleep 3
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
  stop_after=$(grep -c 'E2E_STOP_REQUESTED' "$LOGCAT")
  if [ "$stop_after" -gt "$stop_before" ]; then
    tap_note "RESULT: the tap reached the app (E2E_STOP_REQUESTED in logcat)"
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
  echo "Full dumps: e2e-out/hook_dumpsys_audio.txt, hook_audio_flinger.txt, hook_media_session.txt, hook_notification.txt, hook_shade_*.xml"
} >> "$EXTRA"

echo "hook: done, gating failures=$failures"
[ "$failures" -eq 0 ]
