#!/usr/bin/env bash
# Open a scratch file in nvim. Every save interrupts the previous speech and
# speaks the whole file with Piper (en_US lessac) into the PipeWire sink "virtual-input".
# Piper streams raw PCM into pw-cat, so playback starts before the whole file is rendered.
#
# Engine lifecycle: Piper and pw-cat run as one pipeline inside their own session
# (setsid), so one process group id covers both. Stopping kills the whole group.
# Every exit path (normal quit, Ctrl-C, SIGTERM/HUP, failed synth) runs cleanup,
# which tears the engine down and removes the scratch dir.

PIPER=${PIPER:-piper}
MODEL=${TTS_MODEL:-$HOME/.local/share/piper/en_US-lessac-medium.onnx}
LENGTH=${TTS_LENGTH:-0.9}    # <1 speaks faster
PAUSE=${TTS_PAUSE:-0.2}      # seconds between sentences
RATE=22050                   # sample rate of the lessac-medium model
SINK=${TTS_SINK:-virtual-input}
RUNDIR=${XDG_RUNTIME_DIR:-/tmp}
PIDFILE="$RUNDIR/tts-save.pid"
LOCKFILE="$RUNDIR/tts-save.lock"
SELF=$(readlink -f "$0")

log() { printf 'tts-save: %s\n' "$*" >&2; }

# Returns 0 if every dependency the speak path needs is present.
check_engine() {
    local missing=()
    command -v "$PIPER" >/dev/null || missing+=("$PIPER")
    command -v pw-cat >/dev/null || missing+=(pw-cat)
    [[ -r $MODEL ]] || missing+=("model $MODEL")
    if (( ${#missing[@]} )); then
        log "speech disabled, missing: ${missing[*]}"
        return 1
    fi
}

# Kill the engine group recorded in PIDFILE: TERM first, KILL if it lingers.
stop_playback() {
    spd-say -C >/dev/null 2>&1
    [[ -f $PIDFILE ]] || return 0
    local pgid
    pgid=$(<"$PIDFILE")
    if [[ $pgid =~ ^[0-9]+$ ]] && kill -0 -- "-$pgid" 2>/dev/null; then
        kill -TERM -- "-$pgid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 -- "-$pgid" 2>/dev/null || break
            sleep 0.05
        done
        kill -KILL -- "-$pgid" 2>/dev/null
    fi
    rm -f -- "$PIDFILE"
}

speak() {
    local src=$1

    # Serialize stop+start so rapid saves can't leave two engines running
    exec 9>"$LOCKFILE"
    flock 9

    stop_playback
    grep -q '[^[:space:]]' "$src" || return 0

    # One setsid wraps the whole pipeline, so $! is the pgid shared by piper and pw-cat
    setsid bash -c '"$1" -m "$2" --output-raw --length-scale "$3" --sentence-silence "$4" < "$5" 2>/dev/null |
        pw-cat --playback --raw --target "$6" --format s16 --rate "$7" --channels 1 - >/dev/null 2>&1' _ \
        "$PIPER" "$MODEL" "$LENGTH" "$PAUSE" "$src" "$SINK" "$RATE" 9>&- &
    echo $! > "$PIDFILE"
}

cleanup() {
    trap - EXIT INT TERM HUP
    stop_playback
    [[ -n ${WORK:-} ]] && rm -rf -- "$WORK"
}

main() {
    WORK=$(mktemp -d "$RUNDIR/tts-save.XXXXXX") || exit 1
    local scratch=$WORK/scratch.txt
    : > "$scratch"

    trap cleanup EXIT INT TERM HUP

    local -a nvim_args=("$scratch")
    if check_engine; then
        nvim_args=(-c "autocmd BufWritePost <buffer> silent! !$SELF --speak %:p"
                   -c "autocmd VimLeavePre * silent! !$SELF --stop" "${nvim_args[@]}")
    fi
    nvim "${nvim_args[@]}"
}

if [[ ${1:-} == --speak ]]; then
    # No EXIT trap here: the engine must outlive this short-lived process
    check_engine && speak "$2"
elif [[ ${1:-} == --stop ]]; then
    exec 9>"$LOCKFILE"; flock 9
    stop_playback
else
    main
fi
