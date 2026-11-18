#!/usr/bin/env bash
set -uo pipefail

# Toggle the wayscriber annotation overlay (one-shot, no standby daemon).
# - Already open -> close it.
# - Otherwise -> detect the monitor under the cursor and open it there.
#
# Monitor detection: slurp maps a transparent point-pick surface on every
# output and resolves on the next click. Since it gets a pointer-enter event
# for whichever output the cursor already rests on the moment it maps, a
# synthetic click (via wlrctl's virtual-pointer, at the cursor's current
# position) resolves it immediately, without waiting on the user.

if pgrep -x wayscriber >/dev/null; then
    pkill -TERM -x wayscriber
fi

if pgrep -x slurp >/dev/null; then
    pkill -x slurp
    exit 0
fi

pick=$(mktemp)
trap 'rm -f "$pick"' EXIT

timeout 5 slurp -p -b 00000000 -f '%o' > "$pick" &
slurp_pid=$!
sleep 0.05
wlrctl pointer click >/dev/null 2>&1
wait "$slurp_pid"

output=$(cat "$pick")

if [ -z "$output" ] || [ "$output" = "<unknown>" ]; then
    exit 0
fi

niri msg action focus-monitor "$output"
exec wayscriber --active

