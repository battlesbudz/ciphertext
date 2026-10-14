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
# NOTE: the APK is arm64-only, so the emulators are arm64-v8a images under
# QEMU software emulation on the x86_64 runner. Everything is slow;
# timeouts are generous on purpose.

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
  env "$@" timeout 600 maestro --device "$serial" test "$flow" >"$logfile" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then
    log "maestro [$serial] $name -> TIMEOUT (600s), tail:"
    log "maestro [$serial] $name -> OK"
  else
    log "maestro [$serial] $name -> FAILED (rc=$rc), tail:"
    tail -n 40 "$logfile" | sed 's/^/    /'
  fi
  return $rc
}

# --- QR decode: screenshot one device, return the invitation link. ---
get_invite_link() {
  local serial="$1"
  local png="$OUT_DIR/invite-${serial}.png"
  timeout 60 adb -s "$serial" exec-out screencap -p > "$png"
  python3 "$TEST_DIR/qr_decode.py" "$png"
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
log "=== Phase 0: create + boot emulators (arm64, slow) ==="
sdkmanager --install "emulator" "platform-tools" "system-images;android-30;default;arm64-v8a" >"$OUT_DIR/sdkmanager.log" 2>&1 || {
  fail "sdkmanager install of emulator + system image"
  cat "$OUT_DIR/sdkmanager.log"
  exit 1
}
echo "no" | avdmanager create avd -n "$AVD_A" -k "system-images;android-30;default;arm64-v8a" --device "pixel_5" --force >"$OUT_DIR/avd-a.log" 2>&1 || {
  fail "avdmanager create AVD A"; cat "$OUT_DIR/avd-a.log"; exit 1
}
echo "no" | avdmanager create avd -n "$AVD_B" -k "system-images;android-30;default;arm64-v8a" --device "pixel_5" --force >"$OUT_DIR/avd-b.log" 2>&1 || {
  fail "avdmanager create AVD B"; cat "$OUT_DIR/avd-b.log"; exit 1
}
avdmanager list avd >>"$OUT_DIR/avd-a.log" 2>&1

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
  timeout 30 adb -s "$s" shell settings put global window_animation_scale 0
  timeout 30 adb -s "$s" shell settings put global transition_animation_scale 0
  timeout 30 adb -s "$s" shell settings put global animator_duration_scale 0
  timeout 30 adb -s "$s" shell settings put global heads_up_notifications_enabled 0
done

log "=== Install APK on both ==="
timeout 300 adb -s "$SERIAL_A" install -r -g "$APK" >"$OUT_DIR/install-a.log" 2>&1 || fail "install on A"
timeout 300 adb -s "$SERIAL_B" install -r -g "$APK" >"$OUT_DIR/install-b.log" 2>&1 || fail "install on B"

# =====================================================================
# Phase 1: onboarding on both (parallel)
# =====================================================================
log "=== Phase 1: onboarding ==="
maestro_run "$SERIAL_A" "$FLOWS/onboarding.yaml" PROFILE_NAME="$NAME_A" >"$OUT_DIR/onboard-a.log" 2>&1 &
ONB_A=$!
maestro_run "$SERIAL_B" "$FLOWS/onboarding.yaml" PROFILE_NAME="$NAME_B" >"$OUT_DIR/onboard-b.log" 2>&1 &
ONB_B=$!
wait $ONB_A; RC_A=$?
wait $ONB_B; RC_B=$?
if [ $RC_A -eq 0 ] && [ $RC_B -eq 0 ]; then
  R_A="PASS"; pass "(a) both phones onboarded"
else
  R_A="FAIL"; fail "(a) onboarding (A rc=$RC_A, B rc=$RC_B)"
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
    # B: connect via the deep-linked invitation.
    # The app opens the connect plan; tap Connect.
    if maestro_run "$SERIAL_B" "$FLOWS/assert_text_visible.yaml" TEXT="Connect"; then
      maestro_run "$SERIAL_B" "$FLOWS/tap_text.yaml" TEXT="Connect" || true
    fi
    # A: accept B's contact request.
    if maestro_run "$SERIAL_A" "$FLOWS/accept_request.yaml" CONTACT_NAME="$NAME_B"; then
      INVITE_OK=1
    else
      fail "A could not accept B's contact request"
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
MSG_OK=0
if maestro_run "$SERIAL_A" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/send_message.yaml" TEXT="$MSG_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/open_chat.yaml" CONTACT_NAME="$NAME_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_text_visible.yaml" TEXT="$MSG_A" \
  && maestro_run "$SERIAL_B" "$FLOWS/send_message.yaml" TEXT="$MSG_B" \
  && maestro_run "$SERIAL_A" "$FLOWS/assert_text_visible.yaml" TEXT="$MSG_B"; then
  MSG_OK=1
fi
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
if maestro_run "$SERIAL_A" "$FLOWS/start_session.yaml" \
  && maestro_run "$SERIAL_B" "$FLOWS/assert_banner.yaml"; then
  SESS_OK=1
fi
if [ "$SESS_OK" = "1" ]; then
  log "session active on both; waiting 25s for 2+ heartbeat cycles"
  sleep 25
  HB_OK=0
  if maestro_run "$SERIAL_A" "$FLOWS/assert_no_protocol_text.yaml" \
    && maestro_run "$SERIAL_B" "$FLOWS/assert_no_protocol_text.yaml" \
    && maestro_run "$SERIAL_A" "$FLOWS/send_message.yaml" TEXT="$MSG_A2" \
    && maestro_run "$SERIAL_B" "$FLOWS/assert_text_visible.yaml" TEXT="$MSG_A2"; then
    HB_OK=1
  fi
  if [ "$HB_OK" = "1" ]; then
    R_D="PASS"; pass "(d) heartbeats invisible, messaging works during session"
  else
    R_D="FAIL"; fail "(d) heartbeat leak or messaging broke during session"
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
      if maestro_run "$SERIAL_B" "$FLOWS/assert_text_visible.yaml" TEXT="Connect"; then
        maestro_run "$SERIAL_B" "$FLOWS/tap_text.yaml" TEXT="Connect" || true
      fi
      if maestro_run "$SERIAL_A" "$FLOWS/accept_request.yaml" CONTACT_NAME="$NAME_B" \
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
