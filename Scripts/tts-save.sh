#!/usr/bin/env bash
# Open a scratch file in nvim. Every save cancels the previous speech and speaks
# the whole file with Kokoro into the PipeWire sink.
#
# The Kokoro worker is a child of this script, in its own process group together
# with pw-cat, so one signal stops both. It lives as long as the nvim session.

set -u

PY=${TTS_PYTHON:-$HOME/.local/share/tts-kokoro/venv/bin/python}
SINK=${TTS_SINK:-virtual-input}
SELF=$(readlink -f -- "$0")
WORKER=$(dirname -- "$SELF")/tts-kokoro-worker.py
RATE=24000                           # Kokoro output rate
RUNDIR=${XDG_RUNTIME_DIR:-/tmp}
CURRENT=$RUNDIR/tts-save.current     # holds the live session dir
LOCK=$RUNDIR/tts-save.lock

log() { printf 'tts-save: %s\n' "$*" >&2; }

start_engine() {
    mkfifo "$WORK/in" || return 1

    # Ignore USR1 until the worker installs its own handler, so an early cancel can't kill it
    trap '' USR1

    # misaki shells out to `uv pip` for its language model and needs to know the venv
    export VIRTUAL_ENV=${PY%/bin/*}

    # 7<> opens the FIFO read-write, so neither side blocks waiting for the other
    setsid bash -c '"$1" "$2" "$3" <&7 | pw-cat --playback --raw --target "$4" --format s16 --rate "$5" --channels 1 - >/dev/null 2>&1' _ \
        "$PY" "$WORKER" "$WORK/worker.pid" "$SINK" "$RATE" 7<>"$WORK/in" &
    echo $! > "$WORK/pgid"
    printf '%s\n' "$WORK" > "$CURRENT"
}

# Cancel whatever is playing, then queue this file for the worker.
speak() {
    local src=$1 work pid
    exec 9>"$LOCK"
    flock 9

    grep -q '[^[:space:]]' "$src" || return 0
    work=$(<"$CURRENT" 2>/dev/null) || { log "engine not running"; return 1; }
    pid=$(<"$work/worker.pid" 2>/dev/null) || { log "engine not running"; return 1; }
    kill -USR1 "$pid" 2>/dev/null || { log "engine not running"; return 1; }
    printf '%s\n' "$src" > "$work/in"
}

cleanup() {
    trap - EXIT INT TERM HUP
    if [[ -f $WORK/pgid ]]; then
        local pgid
        pgid=$(<"$WORK/pgid")
        if kill -TERM -- "-$pgid" 2>/dev/null; then
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 -- "-$pgid" 2>/dev/null || break
                sleep 0.05
            done
            kill -KILL -- "-$pgid" 2>/dev/null
        fi
    fi
    [[ $(<"$CURRENT" 2>/dev/null) == "$WORK" ]] && rm -f -- "$CURRENT"
    rm -rf -- "$WORK"
}

main() {
    WORK=$(mktemp -d "$RUNDIR/tts-save.XXXXXX") || exit 1
    local scratch=$WORK/scratch.txt
    : > "$scratch"
    trap cleanup EXIT INT TERM HUP

    local -a nvim_args=("$scratch")
    if [[ -x $PY && -r $WORKER ]] && command -v pw-cat >/dev/null; then
        start_engine
        nvim_args=(-c "autocmd BufWritePost <buffer> silent! !$SELF --speak %:p" "${nvim_args[@]}")
    else
        log "speech disabled (need $PY, $WORKER and pw-cat)"
    fi
    nvim "${nvim_args[@]}"
}

if [[ ${1:-} == --speak ]]; then
    speak "$2"
else
    main
fi
