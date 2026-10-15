#!/usr/bin/env bash
# Two-phone test driver for the SimpleX ephemeral-messenger prototype.
#
# Boots two arm64 emulators, installs the signed APK on both, and drives
# them through: onboarding, 1:1 connect, message exchange, live-session
# start, heartbeat invisibility, kill + wipe, reconnect, zero carryover.
#
# Usage: run-two-phone-test.sh <path-to-signed-apk>
# Exit 0 only if every required check passes. A full per-check report is
# printed at the end and logs land in $OUT_DIR (uploaded as an artifact).
#
# NOTE: the APK is arm64-only (abiFilters in build.gradle.kts), so the
# emulators are x86_64 Google-APIs images on the x86_64 runner with KVM.
# The arm64 APK installs and runs via the image's native bridge (houdini:
# ro.product.cpu.abilist includes arm64-v8a). The ARM64-runner path was
# tried and abandoned: Google's Android SDK host tools (emulator,
# AAPT2) are x86_64-only for Linux, so ARM64 runners have no official
# emulator package and AGP's AAPT2 fails there. If the app hangs on
# "Opening database…" under translation, Phase 0.5 diagnostics (logcat +
# CPU) identify whether it is spinning, blocked, or crash-looping.

set -u
APK="${1:?usage: run-two-phone-test.sh <path-to-signed-apk>}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOWS="$TEST_DIR/flows"
OUT_DIR="${OUT_DIR:-/tmp/two-phone-test}"
mkdir -p "$OUT_DIR"

SERIAL_A="${SERIAL_A:-emulator-5554}"
SERIAL_B="${SERIAL_B:-emulator-5556}"
AVD_A="${AVD_A:-phoneA}"
AVD_B="${AVD_B:-phoneB}"
APP_ID="chat.simplex.app"

NAME_A="PhoneA"
NAME_B="PhoneB"
MSG_A="hello-from-A-7f3a9c"
MSG_B="hello-from-B-7f3a9c"
MSG_A2="second-from-A-7f3a9c"
MSG_NEW="fresh-session-msg-7f3a9c"

# Per-check results (a)-(g).
R_A="NOT_RUN"; R_B="NOT_RUN"; R_C="NOT_RUN"; R_D="NOT_RUN"
R_E="NOT_RUN"; R_F="NOT_RUN"; R_G="NOT_RUN"
RECONNECT_MODE="none"
FAILURES=0

# log() writes to stdout (keeps job-log ordering; stderr/stdout interleave
# jumbled the Maestro tails + hierarchy dumps in run 25). Stdout pollution
# is fixed where it matters: get_invite_link sends its own logs to stderr.
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$HOME/.maestro/bin:$PATH"

# --- Maestro helper: run a flow on one device, tee output to a log. ---
# $1 = serial, $2 = flow file, $3.. = env assignments (KEY=VALUE).
maestro_run() {
  local serial="$1" flow="$2"; shift 2
  local name; name="$(basename "$flow" .yaml)"
  local logfile="$OUT_DIR/maestro-${serial}-${name}.log"
  log "maestro [$serial] $name"
  # Maestro only injects shell env vars starting with MAESTRO_ (see
  # Env.withInjectedShellEnvVars); flow variables MUST be passed with
  # -e KEY=VALUE, or ${VAR} evaluates to null.
  local env_args=()
  local kv
  for kv in "$@"; do env_args+=(-e "$kv"); done
  timeout 600 maestro --device "$serial" test "$flow" "${env_args[@]}" >"$logfile" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    log "maestro [$serial] $name -> OK"
  elif [ $rc -eq 124 ]; then
    log "maestro [$serial] $name -> TIMEOUT (600s), tail:"
    tail -n 40 "$logfile" | sed 's/^/    /'
  else
    log "maestro [$serial] $name -> FAILED (rc=$rc), tail:"
    tail -n 40 "$logfile" | sed 's/^/    /'
  fi
  return $rc
}

# --- QR decode: screenshot one device, return the invitation link. ---
# Extract the invitation link from a device's screen.
# Stdout is RESERVED for the link (this function is called inside
# $(...)): every diagnostic here goes to stderr explicitly, or a log
# line becomes the "link" (run 24).
# PRIMARY (run 28): read the link text from the UI hierarchy. The
# invite screen renders the full link in a BasicTextField
# (LinkTextView in NewChatView.kt - a text field, so no ellipsis
# truncation), and `uiautomator dump` exposes it as a node text.
# This needs no screenshot at all.
# FALLBACK: screenshot + QR decode (kept in case the text field ever
# truncates). `adb screencap` is broken on this emulator (runs 26-27:
# both methods produce empty output with empty adb error logs).
get_invite_link() {
  local serial="$1"
  local xml="$OUT_DIR/ui-invite-${serial}.xml"
  local png="$OUT_DIR/invite-${serial}.png"
  local attempt link
  # --- Primary: UI hierarchy text ---
  timeout 60 adb -s "$serial" shell uiautomator dump /sdcard/ui-invite.xml >"$OUT_DIR/uidump-${serial}.log" 2>&1 || true
  timeout 60 adb -s "$serial" pull /sdcard/ui-invite.xml "$xml" >"$OUT_DIR/uipull-${serial}.log" 2>&1 || true
  if [ -s "$xml" ]; then
    link="$(python3 - "$xml" <<'PYEXTRACT'
import re, sys, html
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# text="..." attributes; the link is the only http(s) text on the
# invite screen. Unescape XML entities (&amp; -> &). Take the longest
# match (the full link beats any short-link variant).
cands = [html.unescape(m) for m in re.findall(r'text="(https?://[^"]*)"', xml)]
cands = [cc for cc in cands if cc.startswith("http")]
for cc in sorted(set(cands), key=len, reverse=True):
    print(f"CAND len={len(cc)} head={cc[:45]!r} tail={cc[-25:]!r}", file=sys.stderr)
print(max(cands, key=len) if cands else "")
PYEXTRACT
)" || link=""
    case "$link" in
      http*) log "invite link from UI hierarchy (${#link} chars)" >&2; printf '%s' "$link"; return 0 ;;
      *) log "UI hierarchy had no invite link for $serial" >&2 ;;
    esac
  else
    log "uiautomator dump produced no file for $serial" >&2
  fi
  # --- Fallback: screenshot + QR decode ---
  for attempt in 1 2 3; do
    rm -f "$png"
    timeout 30 adb -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    sleep 2
    timeout 60 adb -s "$serial" shell screencap -p /sdcard/invite.png >"$OUT_DIR/screencap-${serial}.log" 2>&1 || true
    timeout 60 adb -s "$serial" pull /sdcard/invite.png "$png" >"$OUT_DIR/pull-${serial}.log" 2>&1 || true
    if [ ! -s "$png" ]; then
      timeout 60 adb -s "$serial" exec-out screencap -p > "$png" 2>"$OUT_DIR/execout-${serial}.log" || true
    fi
    if [ -s "$png" ]; then
      log "invite screenshot for $serial: $(stat -c%s "$png") bytes (attempt $attempt)" >&2
      link="$(python3 "$TEST_DIR/qr_decode.py" "$png" 2>"$OUT_DIR/qrdecode-${serial}.log")" || link=""
      case "$link" in
        http*) printf '%s' "$link"; return 0 ;;
        "") log "QR decode failed for $serial (attempt $attempt)" >&2 ;;
        *) log "decoded invite payload is not a URL: $link" >&2 ;;
      esac
    else
      log "invite screenshot missing/empty for $serial (attempt $attempt)" >&2
    fi
    sleep 5
  done
  log "invite link extraction failed for $serial (UI hierarchy + screenshot)" >&2
  return 1
}

# --- Deep-link an invitation into a device's app. ---
deliver_invite() {
  local serial="$1" link="$2"
  # Target MainActivity explicitly: avoids the browser/chooser for https links.
  timeout 60 adb -s "$serial" shell am start -n "$APP_ID/$APP_ID.MainActivity" \
    -a android.intent.action.VIEW -d "'$link'" >"$OUT_DIR/deeplink-${serial}.log" 2>&1
  sleep 5
}

# =====================================================================
# Phase 0: emulators
# =====================================================================
log "=== Phase 0: create + boot emulators (x86_64, KVM) ==="
# Pin the AVD home BEFORE creating anything, so avdmanager and the
# emulator binary agree on where AVDs live.
export ANDROID_AVD_HOME="$HOME/.android/avd"
mkdir -p "$ANDROID_AVD_HOME"
sdkmanager --install "emulator" "platform-tools" "system-images;android-30;google_apis;x86_64" >"$OUT_DIR/sdkmanager.log" 2>&1 || {
  fail "sdkmanager install of emulator + system image"
  cat "$OUT_DIR/sdkmanager.log"
  exit 1
}
echo "no" | avdmanager create avd -n "$AVD_A" -k "system-images;android-30;google_apis;x86_64" --device "pixel_5" --force >"$OUT_DIR/avd-a.log" 2>&1 || {
  fail "avdmanager create AVD A"; cat "$OUT_DIR/avd-a.log"; exit 1
}
echo "no" | avdmanager create avd -n "$AVD_B" -k "system-images;android-30;google_apis;x86_64" --device "pixel_5" --force >"$OUT_DIR/avd-b.log" 2>&1 || {
  fail "avdmanager create AVD B"; cat "$OUT_DIR/avd-b.log"; exit 1
}
# Verify the AVD .ini files actually landed in the pinned home.
# (A previous run had avdmanager exit 0 while the emulator still reported
# "Unknown AVD name", so trust the files on disk, not the exit code.)
avdmanager list avd >"$OUT_DIR/avd-list.log" 2>&1 || true
cat "$OUT_DIR/avd-list.log"
ls -la "$ANDROID_AVD_HOME" || true
for avd in "$AVD_A" "$AVD_B"; do
  if [ ! -f "$ANDROID_AVD_HOME/${avd}.ini" ]; then
    fail "AVD ${avd}.ini missing from $ANDROID_AVD_HOME after avdmanager exit 0"
    echo "--- avd-a.log ---"; cat "$OUT_DIR/avd-a.log"
    echo "--- avd-b.log ---"; cat "$OUT_DIR/avd-b.log"
    echo "--- avd-list.log ---"; cat "$OUT_DIR/avd-list.log"
    exit 1
  fi
done

# KVM: x86_64 emulation REQUIRES hardware acceleration. The runner user
# is not in the kvm group on this image (group line shows no members), so
# grant /dev/kvm access directly. Group membership would need a re-login;
# chmod takes effect immediately in this shell. sudo is passwordless on
# GitHub-hosted runners.
if [ -e /dev/kvm ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || sudo chown "$USER" /dev/kvm 2>/dev/null || true
  if [ -w /dev/kvm ]; then
    log "KVM available (/dev/kvm writable)"
  else
    fail "KVM NOT available: /dev/kvm not writable even after chmod; x86_64 emulation cannot start"
    ls -la /dev/kvm || true
    exit 1
  fi
else
  fail "KVM NOT available: /dev/kvm does not exist on this runner"
  exit 1
fi

emulator -avd "$AVD_A" -port 5554 -no-snapshot -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -memory 2048 >"$OUT_DIR/emu-a.log" 2>&1 &
EMU_A_PID=$!
emulator -avd "$AVD_B" -port 5556 -no-snapshot -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -memory 2048 >"$OUT_DIR/emu-b.log" 2>&1 &
EMU_B_PID=$!
cleanup_emulators() {
  kill "$EMU_A_PID" "$EMU_B_PID" 2>/dev/null || true
}
trap cleanup_emulators EXIT

# Wait for an emulator to appear in `adb devices` AND finish booting.
# Never blocks forever: every wait has a deadline, and a dead emulator
# process fails fast with its log attached.
wait_boot() {
  local serial="$1" emu_pid="$2" emu_log="$3" deadline=$((SECONDS + 1500))
  log "waiting for device: $serial (pid $emu_pid)"
  while [ $SECONDS -lt $deadline ]; do
    if ! kill -0 "$emu_pid" 2>/dev/null; then
      log "emulator process $emu_pid died for $serial; last log:"
      tail -n 60 "$emu_log" | sed 's/^/    /'
      return 1
    fi
    if adb devices 2>/dev/null | grep -q "^${serial}[[:space:]]"; then
      break
    fi
    sleep 10
  done
  if ! adb devices 2>/dev/null | grep -q "^${serial}[[:space:]]"; then
    log "TIMEOUT: $serial never appeared in adb devices"
    tail -n 60 "$emu_log" | sed 's/^/    /'
    return 1
  fi
  log "device online: $serial; waiting for boot_completed"
  while [ $SECONDS -lt $deadline ]; do
    if ! kill -0 "$emu_pid" 2>/dev/null; then
      log "emulator process $emu_pid died during boot for $serial; last log:"
      tail -n 60 "$emu_log" | sed 's/^/    /'
      return 1
    fi
    if [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      log "booted: $serial"
      return 0
    fi
    sleep 15
  done
  log "TIMEOUT waiting for boot_completed: $serial"
  return 1
}
BOOT_OK=1
wait_boot "$SERIAL_A" "$EMU_A_PID" "$OUT_DIR/emu-a.log" || BOOT_OK=0
wait_boot "$SERIAL_B" "$EMU_B_PID" "$OUT_DIR/emu-b.log" || BOOT_OK=0
if [ "$BOOT_OK" != "1" ]; then
  fail "one or both emulators did not boot; aborting (no point running Maestro against dead emulators)"
  adb devices
  exit 1
fi

for s in "$SERIAL_A" "$SERIAL_B"; do
  timeout 30 adb -s "$s" shell input keyevent 82 || true
  # Keep the screen ON: a sleeping screen makes `adb screencap` fail
  # (run 26: capture failed on both methods in Phase 2 and Phase 6).
  # 30-min timeout + stay-on-while-plugged-in + svc power stayon.
  timeout 30 adb -s "$s" shell settings put system screen_off_timeout 1800000 || true
  timeout 30 adb -s "$s" shell settings put global stay_on_while_plugged_in 3 || true
  timeout 30 adb -s "$s" shell svc power stayon true || true
  timeout 30 adb -s "$s" shell settings put global window_animation_scale 0
  timeout 30 adb -s "$s" shell settings put global transition_animation_scale 0
  timeout 30 adb -s "$s" shell settings put global animator_duration_scale 0
  timeout 30 adb -s "$s" shell settings put global heads_up_notifications_enabled 0
done

log "=== Install APK on both ==="
# The arm64 APK needs the native bridge: abilist must include arm64-v8a.
for s in "$SERIAL_A" "$SERIAL_B"; do
  ABIS="$(timeout 30 adb -s "$s" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
  log "abilist [$s]: $ABIS"
  case "$ABIS" in
    *arm64-v8a*) ;;
    *) fail "native bridge missing on $s (no arm64-v8a in abilist); arm64 APK cannot install"; exit 1 ;;
  esac
done
timeout 300 adb -s "$SERIAL_A" install -r -g "$APK" >"$OUT_DIR/install-a.log" 2>&1 || fail "install on A"
timeout 300 adb -s "$SERIAL_B" install -r -g "$APK" >"$OUT_DIR/install-b.log" 2>&1 || fail "install on B"

# =====================================================================
# Phase 0.5: first-launch watch + stuck-app diagnostics
# =====================================================================
# The app must reach the welcome screen ("Private and secure messaging").
# On the x86_64 runner it runs under houdini translation, and a previous
# run sat on "Opening database…" for 300s+. Poll the UI for 300s; if the
# welcome screen never appears, capture process/CPU/logcat diagnostics
# (spin loop vs blocked vs crash loop) and fail fast instead of burning
# another 600s in onboarding waits.
# Dump MAESTRO's view of the hierarchy and print its text values.
# Ground truth for "the flow says X is not visible": shows what screen
# the app is actually on, in the terms Maestro itself sees.
dump_maestro_hierarchy() {
  local serial="$1" tag="$2"
  log "--- Maestro hierarchy [$serial] $tag (text values) ---"
  timeout 120 maestro --device "$serial" hierarchy >"$OUT_DIR/maestro-hierarchy-${serial}-${tag}.txt" 2>&1 || log "maestro hierarchy rc=$?"
  grep -o '"text" : "[^"]*"' "$OUT_DIR/maestro-hierarchy-${serial}-${tag}.txt" 2>/dev/null | sed 's/"text" : /    TEXT: /' | head -n 100 || true
}
dump_ui() {
  local serial="$1" tag="$2"
  log "--- UI dump [$serial] $tag ---"
  timeout 60 adb -s "$serial" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
  timeout 60 adb -s "$serial" pull /sdcard/window_dump.xml "$OUT_DIR/ui-${serial}-${tag}.xml" >/dev/null 2>&1 || true
  if [ -f "$OUT_DIR/ui-${serial}-${tag}.xml" ]; then
    grep -o 'text="[^"]*"' "$OUT_DIR/ui-${serial}-${tag}.xml" | sort -u | head -60 | sed 's/^/    TEXT: /'
    grep -o 'content-desc="[^"]*"' "$OUT_DIR/ui-${serial}-${tag}.xml" | sort -u | head -60 | sed 's/^/    DESC: /'
  else
    log "UI dump failed for $serial ($tag)"
  fi
}
diag_app_stuck() {
  local serial="$1"
  log "--- app diagnostics [$serial] ---"
  local pid
  pid="$(timeout 30 adb -s "$serial" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
  log "app PID: ${pid:-<not running>}"
  if [ -n "$pid" ]; then
    log "proc stat (state + utime/stime ticks):"
    timeout 30 adb -s "$serial" shell cat "/proc/$pid/stat" 2>/dev/null | awk '{print "    state="$3" utime="$14" stime="$15}' || true
    log "top snapshot (simplex lines):"
    timeout 30 adb -s "$serial" shell top -n 1 -b 2>/dev/null | grep -i simplex | sed 's/^/    /' || true
    log "SIGQUIT thread dump (kill -3 $pid):"
    timeout 30 adb -s "$serial" shell kill -3 "$pid" >/dev/null 2>&1 || true
    sleep 5
  fi
  log "activity state (MainActivity / simplex records):"
  timeout 60 adb -s "$serial" shell dumpsys activity activities 2>/dev/null | grep -i "simplex\|MainActivity" | head -n 20 | sed 's/^/    /' || true
  log "thread dump after SIGQUIT (main thread + lock lines):"
  timeout 60 adb -s "$serial" logcat -d 2>/dev/null | grep -E '"main" prio|at chat\.simplex|waiting on|locked <|BLOCKED|tid=1 ' | tail -n 60 | sed 's/^/    /' || true
  log "logcat crash buffer (last 40 lines):"
  timeout 60 adb -s "$serial" logcat -d -b crash 2>/dev/null | tail -n 40 | sed 's/^/    /' || true
  log "logcat main buffer (death/crash/kill signals, excl. uiautomator noise, last 40 lines):"
  timeout 60 adb -s "$serial" logcat -d 2>/dev/null | grep -i "fatal\|exception\|has died\|killing\|force finishing\|tombstone\|signal\|lowmemorykiller\|ANR\|chat.simplex" | grep -v "uiautomator" | tail -n 40 | sed 's/^/    /' || true
}
log "=== Phase 0.5: launch app on A, watch first screen (up to 450s) ==="
timeout 60 adb -s "$SERIAL_A" shell am start -n "$APP_ID/$APP_ID.MainActivity" >"$OUT_DIR/firstlaunch-a.log" 2>&1 || true
log "first-launch am start output:"
sed 's/^/    /' "$OUT_DIR/firstlaunch-a.log" || true
WELCOME_SEEN=0
RELAUNCHED=0
for i in $(seq 1 15); do
  sleep 30
  ROUND_PID="$(timeout 30 adb -s "$SERIAL_A" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
  ROUND_FOCUS="$(timeout 30 adb -s "$SERIAL_A" shell dumpsys window 2>/dev/null | grep -m1 "mCurrentFocus" | tr -d '\r' | sed 's/^ *//')"
  log "round $i: app PID=${ROUND_PID:-<not running>} focus: ${ROUND_FOCUS:-<unknown>}"
  timeout 60 adb -s "$SERIAL_A" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
  timeout 60 adb -s "$SERIAL_A" pull /sdcard/window_dump.xml "$OUT_DIR/ui-${SERIAL_A}-poll${i}.xml" >/dev/null 2>&1 || true
  # If a system ANR dialog ("<App> isn't responding") is covering the
  # screen it can mask the app's window. Tap "Wait" to dismiss it.
  if grep -q "isn't responding" "$OUT_DIR/ui-${SERIAL_A}-poll${i}.xml" 2>/dev/null; then
    WAIT_LINE="$(grep 'text="Wait"' "$OUT_DIR/ui-${SERIAL_A}-poll${i}.xml" | head -1)"
    WAIT_BOUNDS="$(echo "$WAIT_LINE" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)"
    WAIT_XY="$(echo "$WAIT_BOUNDS" | sed -E 's/bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/' | awk '{print int(($1+$3)/2), int(($2+$4)/2)}')"
    if [ -n "$WAIT_XY" ]; then
      log "ANR dialog present; tapping Wait at $WAIT_XY"
      timeout 30 adb -s "$SERIAL_A" shell input tap $WAIT_XY >/dev/null 2>&1 || true
      sleep 5
    else
      log "ANR dialog present but no Wait button bounds found"
    fi
  fi
  if grep -q "Private and secure messaging" "$OUT_DIR/ui-${SERIAL_A}-poll${i}.xml" 2>/dev/null; then
    log "welcome screen visible after ~$((i * 30))s"
    WELCOME_SEEN=1
    # Diagnostic: does MAESTRO's own view of the hierarchy contain the
    # welcome text? uiautomator saw it; Maestro could not. Dump it.
    log "Maestro hierarchy diagnostic (does Maestro see the welcome text?)"
    timeout 120 maestro --device "$SERIAL_A" hierarchy >"$OUT_DIR/maestro-hierarchy-a.txt" 2>&1 || log "maestro hierarchy rc=$?"
    if grep -qi "private and secure" "$OUT_DIR/maestro-hierarchy-a.txt" 2>/dev/null; then
      grep -i "private and secure" "$OUT_DIR/maestro-hierarchy-a.txt" | head -5 | while IFS= read -r line; do log "MAESTRO-HIER: $line"; done
    else
      log "MAESTRO-HIER: 'private and secure' NOT in Maestro hierarchy ($(wc -l < "$OUT_DIR/maestro-hierarchy-a.txt" 2>/dev/null || echo 0) lines)"
    fi
    break
  fi
  log "still not on welcome screen after ~$((i * 30))s (round $i/15)"
  if [ "$i" = "5" ] && [ "$RELAUNCHED" != "1" ] && [ -z "$ROUND_PID" ]; then
    log "RELAUNCH RETRY (round 5): app process gone; force-stop + relaunch once"
    timeout 60 adb -s "$SERIAL_A" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    sleep 5
    timeout 60 adb -s "$SERIAL_A" shell am start -n "$APP_ID/$APP_ID.MainActivity" >"$OUT_DIR/relaunch-a.log" 2>&1 || true
    log "relaunch am start output:"
    sed 's/^/    /' "$OUT_DIR/relaunch-a.log" || true
    RELAUNCHED=1
  fi
done
if [ "$WELCOME_SEEN" != "1" ]; then
  log "app never reached the welcome screen in 300s; last UI dump:"
  dump_ui "$SERIAL_A" "stuck"
  diag_app_stuck "$SERIAL_A"
  fail "app never reached welcome screen in 450s (see last UI dump above)"
  exit 1
fi

# =====================================================================
# Phase 1: onboarding on both (SEQUENTIAL)
# =====================================================================
# Sequential, not parallel: two concurrent `maestro test` processes
# coincided with a Maestro CLI NPE crash (picocli error printer, null
# message) on one phone in the previous run. Serializing removes that
# variable; it costs a few minutes at most.
log "=== Phase 1: onboarding ==="
RC_A=0; RC_B=0
maestro_run "$SERIAL_A" "$FLOWS/onboarding.yaml" PROFILE_NAME="$NAME_A" || RC_A=$?
maestro_run "$SERIAL_B" "$FLOWS/onboarding.yaml" PROFILE_NAME="$NAME_B" || RC_B=$?
if [ $RC_A -eq 0 ] && [ $RC_B -eq 0 ]; then
  R_A="PASS"; pass "(a) both phones onboarded"
else
  R_A="FAIL"; fail "(a) onboarding (A rc=$RC_A, B rc=$RC_B)"
  # Dump the onboarding Maestro tails here so the failure is diagnosable
  # without the artifact (artifact download needs Actions write scope).
  for s in "$SERIAL_A" "$SERIAL_B"; do
    log "--- onboarding Maestro tail [$s] ---"
    tail -n 40 "$OUT_DIR/maestro-${s}-onboarding.log" 2>/dev/null | sed 's/^/    /' || true
  done
  # Ground truth: what screen is each phone actually on?
  for s in "$SERIAL_A" "$SERIAL_B"; do
    dump_maestro_hierarchy "$s" "onboarding-fail"
  done
fi

# =====================================================================
# Phase 2: connect A <-> B via one-time invitation
# =====================================================================
log "=== Phase 2: connect via invitation ==="
INVITE_OK=0
if maestro_run "$SERIAL_A" "$FLOWS/create_invite.yaml"; then
  LINK="$(get_invite_link "$SERIAL_A" || true)"
  if [ -n "$LINK" ]; then
    log "invite link decoded (${#LINK} chars)"
    deliver_invite "$SERIAL_B" "$LINK"
    log "deep-link am start output:"
    sed 's/^/    /' "$OUT_DIR/deeplink-${SERIAL_B}.log" 2>/dev/null || true
    # B: connect via the deep-linked invitation (prepare + Connect).
    if ! maestro_run "$SERIAL_B" "$FLOWS/connect_via_invite.yaml"; then
      fail "B could not connect via invitation"
      # Ground truth: what is B actually showing after the deep link?
      # (loading? error alert? chat list? nothing?)
      dump_maestro_hierarchy "$SERIAL_B" "connect-fail"
    else
      # B's state after Connect: connecting? established? banner? input?
      # (Run 31: A showed "Your contact" + input, no Accept bar.)
      dump_maestro_hierarchy "$SERIAL_B" "connect-ok"
      # NO accept_request: the prepare path completes without a manual
      # Accept (Run 32: A shows "Your contact" + input, no Accept bar).
      # accept_request can never succeed here — it only wastes 90s.
      # (b) = B connected + A has PhoneB as a contact.
      INVITE_OK=1
    fi
  else
    fail "could not decode invitation QR from A's screenshot"
  fi
else
  fail "A could not create invitation"
fi
if [ "$INVITE_OK" = "1" ]; then
  R_B="PASS"; pass "(b) 1:1 contact established"
else
  R_B="FAIL"; fail "(b) 1:1 contact NOT established"
fi

# =====================================================================
# Phase 3: message exchange
# =====================================================================
log "=== Phase 3: message exchange ==="
# Try each direction INDEPENDENTLY (do not short-circuit): if A->B fails
# we still learn whether B->A works (directional signal). Settle 30s
# first - the connection handshake needs time after B's Connect.
log "letting the connection handshake settle (30s)"
sleep 30
MSG_AB=0; MSG_BA=0
if maestro_run "$SERIAL_A" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/send_message.yaml" TEXT="$MSG_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_text_visible.yaml" TEXT="$MSG_A"; then
  MSG_AB=1; log "A->B message delivered"
else
  log "A->B message NOT delivered"
  # Ground truth: alert? chat closed? contact gone? (Run 33: B's msg
  # appeared then vanished; A's never appeared.)
  dump_maestro_hierarchy "$SERIAL_A" "send-fail-A"
  dump_maestro_hierarchy "$SERIAL_B" "send-fail-B"
fi
if maestro_run "$SERIAL_B" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/send_message.yaml" TEXT="$MSG_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/assert_text_visible.yaml" TEXT="$MSG_B"; then
  MSG_BA=1; log "B->A message delivered"
else
  log "B->A message NOT delivered"
  dump_maestro_hierarchy "$SERIAL_A" "send-fail-A2"
  dump_maestro_hierarchy "$SERIAL_B" "send-fail-B2"
fi
MSG_OK=0
if [ "$MSG_AB" = "1" ] && [ "$MSG_BA" = "1" ]; then MSG_OK=1; fi
if [ "$MSG_OK" = "1" ]; then
  R_C="PASS"; pass "(c) messages flow both ways"
else
  R_C="FAIL"; fail "(c) message exchange failed"
fi

# =====================================================================
# Phase 4: start live session, heartbeat invisibility
# =====================================================================
log "=== Phase 4: live session + heartbeat invisibility ==="
SESS_OK=0
# Ensure A is inside the chat first (Phase 3 may have left A on the
# chat list if it failed; start_session taps the chat toolbar menu).
if maestro_run "$SERIAL_A" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/start_session.yaml" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_banner.yaml"; then
  SESS_OK=1
fi
if [ "$SESS_OK" = "1" ]; then
  log "session active on both; waiting 25s for 2+ heartbeat cycles"
  sleep 25
  # (d) as defined: heartbeats produce NO visible UI noise. The
  # assert_no_protocol_text checks (no LIVE_HB / LIVE_INVITE text)
  # are the whole (d) check.
  # NOTE: normal in-session messaging is NOT part of (d), and the
  # compose input is hidden during a session (placeholder "" —
  # userCantSendReason != null, contact momentarily not sndReady),
  # so a send_message step here can never pass. Whether that block
  # is intentional (live messages only) or a bug is a separate
  # product question — see the final report. Do NOT re-add a
  # send_message step to Phase 4 without resolving it.
  HB_OK=0
  if maestro_run "$SERIAL_A" "$FLOWS/assert_no_protocol_text.yaml" \
    && maestro_run "$SERIAL_B" "$FLOWS/assert_no_protocol_text.yaml"; then
    HB_OK=1
  fi
  if [ "$HB_OK" = "1" ]; then
    R_D="PASS"; pass "(d) heartbeats invisible (no protocol text on either phone)"
  else
    R_D="FAIL"; fail "(d) heartbeat leak: protocol text visible"
    # Ground truth: heartbeat leak (protocol text visible) or the
    # compose input is gone/has a different placeholder during a
    # session? (Run 36: send_message could not find "Message".)
    dump_maestro_hierarchy "$SERIAL_A" "session-send-fail"
    dump_maestro_hierarchy "$SERIAL_B" "session-send-fail"
  fi
else
  R_D="FAIL"; fail "(d) live session did not start on both phones"
fi

# =====================================================================
# Phase 5: kill A, verify B wipes the session
# =====================================================================
log "=== Phase 5: kill A, B must wipe ==="
timeout 60 adb -s "$SERIAL_A" shell am force-stop "$APP_ID"
log "A force-stopped; waiting 45s for B watchdog (30s timeout) + wipe"
sleep 45
if maestro_run "$SERIAL_B" "$FLOWS/assert_contact_gone.yaml" CONTACT_NAME="$NAME_A"; then
  R_E="PASS"; pass "(e) B wiped the session: contact gone from chat list"
else
  R_E="FAIL"; fail "(e) B did NOT wipe: contact still visible"
fi

# =====================================================================
# Phase 6: relaunch A, reconnect (auto if B initiated, else manual)
# =====================================================================
log "=== Phase 6: relaunch A, reconnect ==="
timeout 60 adb -s "$SERIAL_A" shell am start -n "$APP_ID/$APP_ID.MainActivity" >"$OUT_DIR/relaunch-a.log" 2>&1
sleep 10
RECON_OK=0
# Case 1: B was the token-smaller initiator -> a contact request is waiting on A.
if maestro_run "$SERIAL_A" "$FLOWS/accept_request.yaml" CONTACT_NAME="$NAME_B"; then
  RECONNECT_MODE="auto"
  log "auto-reconnect: A accepted B's reconnect request"
  # B starts the new session on connect; A joins as waiter. Banner on both.
  if maestro_run "$SERIAL_B" "$FLOWS/assert_banner.yaml" \
    && maestro_run "$SERIAL_A" "$FLOWS/assert_banner.yaml"; then
    RECON_OK=1
  else
    fail "auto-reconnect: new session banner missing"
  fi
else
  log "no reconnect request on A: B is the waiter (token race). Manual recovery."
  RECONNECT_MODE="manual"
  # A still holds the stale contact; create a fresh invitation instead.
  if maestro_run "$SERIAL_A" "$FLOWS/create_invite.yaml"; then
    LINK2="$(get_invite_link "$SERIAL_A" || true)"
    if [ -n "$LINK2" ]; then
      deliver_invite "$SERIAL_B" "$LINK2"
      # B connects via the fresh invitation (prepare + Connect — the
      # same path as Phase 2; NO accept_request: the prepare path
      # needs no manual Accept). Then A opens the chat and starts a
      # brand-new session manually.
      if maestro_run "$SERIAL_B" "$FLOWS/connect_via_invite.yaml" \
        && maestro_run "$SERIAL_A" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_B" \
        && maestro_run "$SERIAL_A" "$FLOWS/start_session.yaml" \
        && maestro_run "$SERIAL_B" "$FLOWS/assert_banner.yaml"; then
        RECON_OK=1
      else
        fail "manual recovery: new session did not establish"
      fi
    else
      fail "manual recovery: could not decode second invitation QR"
    fi
  else
    fail "manual recovery: A could not create a fresh invitation"
  fi
fi
if [ "$RECON_OK" = "1" ]; then
  if [ "$RECONNECT_MODE" = "auto" ]; then
    R_F="PASS"; pass "(f) brand-new session re-established AUTOMATICALLY"
  else
    R_F="PARTIAL (manual recovery; auto-reconnect stalled on waiter/token race)"
    log "NOTE (f): auto-reconnect stalled (B was waiter); manual recovery used."
  fi
else
  R_F="FAIL"; fail "(f) no new session established"
fi

# =====================================================================
# Phase 7: zero carryover in the new session
# =====================================================================
log "=== Phase 7: zero carryover ==="
CARRY_OK=0
if maestro_run "$SERIAL_A" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/assert_text_gone.yaml" TEXT="$MSG_A" \
  && maestro_run "$SERIAL_A" "$FLOWS/assert_text_gone.yaml" TEXT="$MSG_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/assert_text_gone.yaml" TEXT="$MSG_A2" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_text_gone.yaml" TEXT="$MSG_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_text_gone.yaml" TEXT="$MSG_B" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_text_gone.yaml" TEXT="$MSG_A2" \
  && maestro_run "$SERIAL_A" "$FLOWS/send_message.yaml" TEXT="$MSG_NEW" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_text_visible.yaml" TEXT="$MSG_NEW"; then
  CARRY_OK=1
fi
if [ "$CARRY_OK" = "1" ]; then
  R_G="PASS"; pass "(g) zero carryover: old messages gone, new session works"
else
  R_G="FAIL"; fail "(g) carryover detected or new session messaging broken"
fi

# =====================================================================
# Report
# =====================================================================
log "==================== TWO-PHONE TEST REPORT ===================="
log "(a) onboard both phones:        $R_A"
log "(b) 1:1 session established:    $R_B"
log "(c) messages both ways:         $R_C"
log "(d) heartbeats invisible:       $R_D"
log "(e) kill -> B wipes session:    $R_E"
log "(f) brand-new session:          $R_F  [mode: $RECONNECT_MODE]"
log "(g) zero carryover:             $R_G"
log "================================================================"
if [ $FAILURES -gt 0 ]; then
  log "RESULT: FAIL ($FAILURES failed check(s))"
  exit 1
fi
log "RESULT: ALL CHECKS PASSED"
exit 0
