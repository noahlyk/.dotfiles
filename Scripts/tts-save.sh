#!/usr/bin/env bash
# Open a scratch file in nvim. Every save cancels the previous speech and
# speaks the whole file with Kokoro into the PipeWire sink "virtual-input".
#
# Lifecycle: the Kokoro worker starts when this script opens nvim and is torn
# down when nvim exits, on any exit path (normal quit, Ctrl-C, TERM/HUP, error).
# The worker and pw-cat run in one setsid process group, so one signal stops both.

TTS_PYTHON=${TTS_PYTHON:-$HOME/.local/share/tts-kokoro/venv/bin/python}
SINK=${TTS_SINK:-virtual-input}
SELF=$(readlink -f "$0")
WORKER=$(dirname -- "$SELF")/tts-kokoro-worker.py
RATE=24000                           # Kokoro output rate
RUNDIR=${XDG_RUNTIME_DIR:-/tmp}
CURRENT="$RUNDIR/tts-save.current"   # points at the live session dir
LOCKFILE="$RUNDIR/tts-save.lock"

log() { printf 'tts-save: %s\n' "$*" >&2; }

# Returns 0 if everything the engine needs is present.
check_engine() {
    local missing=()
    [[ -x $TTS_PYTHON ]] || missing+=("python $TTS_PYTHON")
    [[ -r $WORKER ]] || missing+=("worker $WORKER")
    command -v pw-cat >/dev/null || missing+=(pw-cat)
    if (( ${#missing[@]} )); then
        log "speech disabled, missing: ${missing[*]}"
        return 1
    fi
}

# Prints the live worker pid for the current session; fails if it isn't running.
live_worker() {
    [[ -f $CURRENT ]] || return 1
    local work pid
    work=$(<"$CURRENT")
    pid=$(cat "$work/worker.pid" 2>/dev/null) || return 1
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
}

start_engine() {
    local work=$1 pgid
    mkfifo "$work/in" || return 1

    # Ignore USR1 until the worker installs its own handler, so an early cancel can't kill it
    trap '' USR1

    # misaki shells out to `uv pip` for its language model and needs to know the venv
    export VIRTUAL_ENV=${TTS_PYTHON%/bin/*}

    # 7<> opens the FIFO read-write, so neither side blocks waiting for the other
    setsid bash -c '"$1" "$2" "$3" <&7 | pw-cat --playback --raw --target "$4" --format s16 --rate "$5" --channels 1 - >/dev/null 2>&1' _ \
        "$TTS_PYTHON" "$WORKER" "$work/worker.pid" "$SINK" "$RATE" 7<>"$work/in" &
    pgid=$!
    echo "$pgid" > "$work/pgid"
    printf '%s\n' "$work" > "$CURRENT"
}

# Stop the engine group: TERM, then KILL if it lingers. Safe to call twice.
stop_engine() {
    [[ -n ${WORK:-} && -f $WORK/pgid ]] || return 0
    local pgid
    pgid=$(<"$WORK/pgid")
    if kill -0 -- "-$pgid" 2>/dev/null; then
        kill -TERM -- "-$pgid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 -- "-$pgid" 2>/dev/null || break
            sleep 0.05
        done
        kill -KILL -- "-$pgid" 2>/dev/null
    fi
    rm -f -- "$WORK/pgid"
}

# Cancel whatever is playing and queue this file for the worker.
speak() {
    local src=$1 pid
    exec 9>"$LOCKFILE"
    flock 9

    grep -q '[^[:space:]]' "$src" || return 0
    if ! pid=$(live_worker); then
        log "engine not running"
        return 1
    fi
    kill -USR1 "$pid" 2>/dev/null
    printf '%s\n' "$src" > "$(<"$CURRENT")/in"
}

cleanup() {
    trap - EXIT INT TERM HUP
    stop_engine
    if [[ -n ${WORK:-} ]]; then
        [[ $(cat "$CURRENT" 2>/dev/null) == "$WORK" ]] && rm -f -- "$CURRENT"
        rm -rf -- "$WORK"
    fi
}

main() {
    WORK=$(mktemp -d "$RUNDIR/tts-save.XXXXXX") || exit 1
    local scratch=$WORK/scratch.txt
    : > "$scratch"

    trap cleanup EXIT INT TERM HUP

    local -a nvim_args=("$scratch")
    if check_engine && start_engine "$WORK"; then
        nvim_args=(-c "autocmd BufWritePost <buffer> silent! !$SELF --speak %:p" "${nvim_args[@]}")
    fi
    nvim "${nvim_args[@]}"
}

if [[ ${1:-} == --speak ]]; then
    # No EXIT trap here: the engine belongs to the nvim session, not this helper
    speak "$2"
else
    main
fi
