#!/usr/bin/env bash
#
# whisperkey — a minimal hotkey wrapper around whisper.cpp + wtype.
#
# Push-to-talk local dictation for Ubuntu/Wayland. Bind this script to one
# keyboard shortcut, then:
#   1st press -> start recording the mic
#   2nd press -> stop recording, transcribe (whisper.cpp), type at cursor (wtype)
#
# It is thin glue over whisper.cpp + ffmpeg + wtype — no daemon, no extra deps.
# Runs entirely offline. See README.md for prerequisites and setup.

set -euo pipefail

# --- Configuration (override via environment) ---------------------------------
# Defaults target the whisper-cpp snap. A strictly-confined snap can ONLY read
# files under its own data dir (~/snap/whisper-cpp/common) — not $XDG_RUNTIME_DIR
# and not hidden dirs like ~/.local — so both the model and the recorded WAV must
# live there. Override any of these via environment for a native whisper build.
SNAP_DIR="${HOME}/snap/whisper-cpp/common"
MODEL="${WHISPER_MODEL:-${SNAP_DIR}/models/ggml-base.en.bin}"
WHISPER_BIN="${WHISPER_BIN:-whisper-cpp.cli}"
STATE_DIR="${WHISPER_STATE_DIR:-${SNAP_DIR}/whisperkey}"
PID_FILE="${STATE_DIR}/record.pid"
WAV_FILE="${STATE_DIR}/record.wav"
LOCK_FILE="${STATE_DIR}/lock"
LOG_FILE="${STATE_DIR}/whisperkey.log"
NID_FILE="${STATE_DIR}/notify.id"

# Verbose mode: enable with VERBOSE=1 or the -v/--verbose flag. Logs to stderr
# and $LOG_FILE, surfaces ffmpeg/whisper output, and keeps the WAV for inspection.
VERBOSE="${VERBOSE:-0}"
for _arg in "$@"; do
    case "$_arg" in
        -v|--verbose) VERBOSE=1 ;;
    esac
done

mkdir -p "$STATE_DIR"

# Serialize invocations. Without this, spamming the shortcut can race two start
# branches: both write the same WAV and one ffmpeg gets orphaned (untracked PID,
# records forever). flock makes the check-then-act below atomic; if another
# invocation already holds the lock, this press is simply dropped.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

notify() {
    # Best-effort notifications, shown as a single bubble that updates in place
    # across stages instead of stacking. Pass "persist" as $2 to keep it in the
    # notification list for the whole recording; otherwise it's -e transient and
    # fades. The terminal message (Done/error) is transient and replaces the
    # persistent "Recording" one by id, so the indicator clears when finished.
    # The id is persisted to $NID_FILE since each stage is a separate invocation.
    # (-u low is avoided — GNOME hides low-urgency notifications from the banner.)
    command -v notify-send >/dev/null 2>&1 || return 0
    local replace=() transient=(-e) id=""
    [[ "${2:-}" == persist ]] && transient=()
    [[ -s "$NID_FILE" ]] && replace=(-r "$(cat "$NID_FILE")")
    id="$(notify-send "${transient[@]}" -p "${replace[@]}" "WhisperKey" "$1" 2>/dev/null)" || return 0
    [[ -n "$id" ]] && printf '%s' "$id" > "$NID_FILE"
}

log() {
    # No-op unless verbose. Writes to both the terminal (stderr) and $LOG_FILE
    # so logs are captured even when launched from a keyboard shortcut.
    [[ "$VERBOSE" == 1 ]] || return 0
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

log "config: model=$MODEL bin=$WHISPER_BIN"
log "state:  pid=$PID_FILE wav=$WAV_FILE lock=$LOCK_FILE log=$LOG_FILE"

# Fail loudly if the transcriber is missing. Without this the error is swallowed
# (command substitution + stderr to /dev/null) and dictation silently does
# nothing — exactly the bug this guards against.
if ! command -v "$WHISPER_BIN" >/dev/null 2>&1; then
    notify "whisper binary not found: $WHISPER_BIN (see README)"
    log "whisper binary not found on PATH: $WHISPER_BIN"
    exit 1
fi

# --- Stop branch: a recording is already running ------------------------------
# If a live recorder PID exists, this invocation finishes the take and
# transcribes it. A stale PID file (process already gone) falls through to a
# fresh recording.
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    REC_PID="$(cat "$PID_FILE")"
    rm -f "$PID_FILE"
    log "active recording (pid $REC_PID) -> stopping"

    # SIGINT lets ffmpeg flush and finalize the WAV header cleanly.
    kill -INT "$REC_PID" 2>/dev/null || true
    while kill -0 "$REC_PID" 2>/dev/null; do
        sleep 0.05
    done

    log "transcribing $WAV_FILE ($(du -h "$WAV_FILE" 2>/dev/null | cut -f1 || echo '?'))"

    # In verbose mode, capture whisper's stderr (timings, system info) to the log.
    WHISPER_ERR=/dev/null
    [[ "$VERBOSE" == 1 ]] && WHISPER_ERR="$LOG_FILE"
    # --no-timestamps so we get plain text, not "[00:00:00 --> ...] text" lines.
    set +e
    TEXT="$(
        "$WHISPER_BIN" \
            --model "$MODEL" \
            --file "$WAV_FILE" \
            --no-timestamps \
            2>>"$WHISPER_ERR"
    )"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        notify "Transcription failed (rc=$rc) — see $LOG_FILE"
        log "whisper exited $rc"
        [[ "$VERBOSE" == 1 ]] || rm -f "$WAV_FILE"
        exit 1
    fi

    if [[ "$VERBOSE" == 1 ]]; then
        log "WAV kept for inspection: $WAV_FILE (play with: aplay $WAV_FILE)"
    else
        rm -f "$WAV_FILE"
    fi

    # Collapse to a single trimmed line.
    TEXT="$(echo "$TEXT" \
        | tr '\n' ' ' \
        | sed 's/^[[:space:]]*//' \
        | sed 's/[[:space:]]*$//')"

    log "transcript: ${TEXT:-(empty)}"

    if [[ -z "$TEXT" ]]; then
        notify "No speech detected"
        exit 0
    fi

    # Clipboard copy is a fallback in case typing fails or focus is lost.
    # wl-copy daemonizes to own the selection, so close fd 9 or it would inherit
    # and hold our flock indefinitely, wedging the next invocation.
    command -v wl-copy >/dev/null 2>&1 && printf "%s" "$TEXT" | wl-copy 9>&- || true

    # Type into the focused window. wtype needs the virtual-keyboard Wayland
    # protocol: wlroots compositors (Sway, Hyprland, …) support it, but
    # GNOME/Mutter does NOT. If typing fails, the transcript is still on the
    # clipboard, so degrade to a "paste it yourself" prompt instead of aborting.
    if command -v wtype >/dev/null 2>&1 && wtype "$TEXT" 2>>"$WHISPER_ERR"; then
        notify "Done"
    else
        notify "Done (Clipboard set — paste with Ctrl+V)"
        log "wtype failed or unavailable; transcript left on clipboard"
    fi
    exit 0
fi

# --- Start branch: no recording in progress -----------------------------------
# Clean up any stale state, verify the model, then start recording detached so
# the recorder survives this invocation returning to the shortcut handler.
rm -f "$PID_FILE"

if [[ ! -f "$MODEL" ]]; then
    notify "Model missing: $MODEL (run whisper-cpp.download-ggml-model — see README)"
    log "model missing: $MODEL"
    exit 1
fi

notify "🔴 Recording… (press the shortcut again to stop)" persist

# In verbose mode, raise ffmpeg's verbosity and tee its output to the log; otherwise
# stay silent. (fd 9 is closed so the recorder doesn't inherit the flock.)
FF_LOG=quiet
FF_OUT=/dev/null
if [[ "$VERBOSE" == 1 ]]; then
    FF_LOG=info
    FF_OUT="$LOG_FILE"
fi

# Record mono 16 kHz PCM — the format whisper.cpp expects.
setsid ffmpeg \
    -f pulse \
    -i default \
    -ac 1 \
    -ar 16000 \
    -y \
    "$WAV_FILE" \
    -loglevel "$FF_LOG" 9>&- >>"$FF_OUT" 2>&1 &

REC_PID=$!
echo "$REC_PID" > "$PID_FILE"
log "recording started (pid $REC_PID) -> $WAV_FILE"
