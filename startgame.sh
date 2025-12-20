#!/usr/bin/env bash
# startgame.sh
# DSP Start (kein Setup!) + stabiler Xvfb (:99) + Cleanup
# + One-shot self-restart:
#   Wenn innerhalb von ONESHOT_TIMEOUT Sekunden der Server-Ready-Text nicht im Log steht,
#   dann exit 42 -> Docker restartet den Container.
#   Beim nächsten Start (Marker vorhanden) läuft er einfach durch, ohne nochmal zu rebooten.

set -euo pipefail

log() { echo "[$(date -Iseconds)] $*"; }

DATA_ROOT="/data"
SERVER_DIR="$DATA_ROOT/server"
LOG_DIR="$DATA_ROOT/logs"
WINE_DIR="$DATA_ROOT/wine"

export WINEPREFIX="$WINE_DIR"
export WINEDLLOVERRIDES="winhttp=n,b"
export LIBGL_ALWAYS_SOFTWARE=1
export HOME="/root"
export WINEDEBUG="${WINEDEBUG:--all}"

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/unity_headless.log" "$LOG_DIR/console_headless.log"

# ---- Watch/Display stability ----
XVFB_DISPLAY="${XVFB_DISPLAY:-:99}"
XVFB_SCREEN="${XVFB_SCREEN:-1280x720x24}"

# ---- One-shot restart watchdog ----
# Default: enabled, 120s (2 min), log + pattern for Nebula server readiness
ONESHOT_RESTART="${ONESHOT_RESTART:-1}"                 # 1 = enabled, 0 = disabled
ONESHOT_TIMEOUT="${ONESHOT_TIMEOUT:-120}"              # seconds
ONESHOT_LOG="${ONESHOT_LOG:-$SERVER_DIR/BepInEx/LogOutput.log}"
ONESHOT_PATTERN="${ONESHOT_PATTERN:-Listening server on port}"
ONESHOT_MARKER="${ONESHOT_MARKER:-$DATA_ROOT/.oneshot_restart_done}"

# ---- DSP CLI options via env (compose) ----
DSP_LOAD="${DSP_LOAD:-}"
DSP_LOAD_LATEST="${DSP_LOAD_LATEST:-0}"

DSP_NEWGAME_SEED="${DSP_NEWGAME_SEED:-}"
DSP_NEWGAME_STARCOUNT="${DSP_NEWGAME_STARCOUNT:-}"
DSP_NEWGAME_RESOURCE_MULT="${DSP_NEWGAME_RESOURCE_MULT:-}"

DSP_NEWGAME_CFG="${DSP_NEWGAME_CFG:-0}"
DSP_NEWGAME_DEFAULT="${DSP_NEWGAME_DEFAULT:-0}"

DSP_UPS="${DSP_UPS:-}"

# Legacy compatibility
SAVE_NAME="${SAVE_NAME:-}"
NEWGAME_CFG="${NEWGAME_CFG:-}"

ARGS=( -batchmode -hidewindow 1 -nebula-server )

# UPS option
if [[ -n "$DSP_UPS" ]]; then
  ARGS+=( -ups "$DSP_UPS" )
fi

# Decide start mode (priority)
if [[ -n "$DSP_LOAD" ]]; then
  ARGS+=( -load "$DSP_LOAD" )
elif [[ "$DSP_LOAD_LATEST" == "1" ]]; then
  ARGS+=( -load-latest )
elif [[ -n "$DSP_NEWGAME_SEED" || -n "$DSP_NEWGAME_STARCOUNT" || -n "$DSP_NEWGAME_RESOURCE_MULT" ]]; then
  # Require all three if any is set
  if [[ -z "$DSP_NEWGAME_SEED" || -z "$DSP_NEWGAME_STARCOUNT" || -z "$DSP_NEWGAME_RESOURCE_MULT" ]]; then
    echo "ERROR: For -newgame you must set DSP_NEWGAME_SEED, DSP_NEWGAME_STARCOUNT, DSP_NEWGAME_RESOURCE_MULT" >&2
    exit 1
  fi
  ARGS+=( -newgame "$DSP_NEWGAME_SEED" "$DSP_NEWGAME_STARCOUNT" "$DSP_NEWGAME_RESOURCE_MULT" )
elif [[ "$DSP_NEWGAME_CFG" == "1" ]]; then
  ARGS+=( -newgame-cfg )
elif [[ "$DSP_NEWGAME_DEFAULT" == "1" ]]; then
  ARGS+=( -newgame-default )
elif [[ -n "$SAVE_NAME" ]]; then
  if [[ "$SAVE_NAME" == "latest" ]]; then
    ARGS+=( -load-latest )
  else
    ARGS+=( -load "$SAVE_NAME" )
  fi
elif [[ -n "$NEWGAME_CFG" ]]; then
  ARGS+=( -newgame "$NEWGAME_CFG" )
else
  ARGS+=( -newgame-cfg )
fi

ARGS+=( -logFile "Z:\\data\\logs\\unity_headless.log" )

cd "$SERVER_DIR"

log "Launching DSPGAME.exe with args: ${ARGS[*]}"
log "Console log redirect -> $LOG_DIR/console_headless.log"

# -------------------------------
# Cleanup leftovers (important on restarts)
# -------------------------------
log "Cleanup: killing old wine/Xvfb (if any)"
pkill -9 -f 'DSPGAME.exe'  >/dev/null 2>&1 || true
pkill -9 -f 'wine64'       >/dev/null 2>&1 || true
pkill -9 -f 'wineserver'   >/dev/null 2>&1 || true
pkill -9 -f 'Xvfb'         >/dev/null 2>&1 || true

# remove stale X lock for display :99
disp_num="${XVFB_DISPLAY#:}"
rm -f "/tmp/.X${disp_num}-lock" "/tmp/.X11-unix/X${disp_num}" >/dev/null 2>&1 || true

# -------------------------------
# Start fixed Xvfb (:99)
# -------------------------------
export DISPLAY="$XVFB_DISPLAY"
log "Starting Xvfb on DISPLAY=$DISPLAY ..."
Xvfb "$DISPLAY" -screen 0 "$XVFB_SCREEN" -ac +extension GLX +render -noreset \
  >> "$LOG_DIR/console_headless.log" 2>&1 &
XVFB_PID=$!

cleanup() {
  log "Stopping Xvfb (pid=$XVFB_PID)"
  kill "$XVFB_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1

# Ensure oneshot log path exists (file will be written by BepInEx)
mkdir -p "$(dirname "$ONESHOT_LOG")"
touch "$ONESHOT_LOG" >/dev/null 2>&1 || true

# -------------------------------
# Start game (in background, so oneshot watchdog can inspect logs)
# -------------------------------
/usr/lib/wine/wine64 ./DSPGAME.exe "${ARGS[@]}" \
  >> "$LOG_DIR/console_headless.log" 2>&1 &
DSP_PID=$!

# -------------------------------
# One-shot restart logic
# -------------------------------
if [[ "$ONESHOT_RESTART" == "1" && ! -f "$ONESHOT_MARKER" ]]; then
  log "One-shot restart watchdog enabled (timeout=${ONESHOT_TIMEOUT}s, pattern='$ONESHOT_PATTERN', log=$ONESHOT_LOG)"
  start_ts="$(date +%s)"

  while true; do
    # If DSP died early, mark oneshot done and propagate failure
    if ! kill -0 "$DSP_PID" >/dev/null 2>&1; then
      log "DSP exited before one-shot check completed. Marking oneshot done and exiting 1."
      echo "done" > "$ONESHOT_MARKER" || true
      wait "$DSP_PID" || true
      exit 1
    fi

    if grep -qF "$ONESHOT_PATTERN" "$ONESHOT_LOG" 2>/dev/null; then
      log "One-shot watchdog OK: pattern found. Marking oneshot done; continuing normally."
      echo "done" > "$ONESHOT_MARKER" || true
      break
    fi

    now_ts="$(date +%s)"
    elapsed=$((now_ts - start_ts))
    if (( elapsed >= ONESHOT_TIMEOUT )); then
      log "One-shot watchdog FAIL: pattern not found within ${ONESHOT_TIMEOUT}s."
      log "Triggering exactly one container restart (exit 42) and marking oneshot done."
      echo "done" > "$ONESHOT_MARKER" || true

      # Stop DSP so it doesn't keep running while container restarts
      kill "$DSP_PID" >/dev/null 2>&1 || true
      sleep 2
      kill -9 "$DSP_PID" >/dev/null 2>&1 || true

      exit 42
    fi

    sleep 2
  done
else
  if [[ "$ONESHOT_RESTART" != "1" ]]; then
    log "One-shot restart watchdog disabled (ONESHOT_RESTART=$ONESHOT_RESTART)"
  else
    log "One-shot restart already done (marker exists: $ONESHOT_MARKER) -> running normally"
  fi
fi

# -------------------------------
# Keep container alive by waiting on DSP
# -------------------------------
wait "$DSP_PID"
