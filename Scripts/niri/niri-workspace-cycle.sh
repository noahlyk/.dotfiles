#!/bin/bash
# niri-workspace-cycle.sh
#
# Cycle only through the named workspaces on the focused output, in PHYSICAL
# screen order (top-to-bottom), so switching workspaces never creates or lands
# on a blank/unnamed workspace, and mod+direction matches the screen.
#
# Usage:
#   niri-workspace-cycle.sh <next|prev> <focus|move>
#
#   focus  -> focus the target named workspace and land on column 1
#   move   -> move the focused column to the target named workspace, at column 1

set -euo pipefail

dir="${1:-next}"
op="${2:-focus}"

# Get focused output.
output="$(niri msg -j workspaces | jq -r '.[] | select(.is_focused==true) | .output' | head -n1)"
current="$(niri msg -j workspaces | jq -r '.[] | select(.is_focused==true) | .name // ""' | head -n1)"

mapfile -t ordered < <(niri msg -j workspaces | jq -r --arg out "$output" '
    .[] | select(.output == $out and .name != null) | "\(.idx)\t\(.name)"' | sort -n | cut -f2)

if [ "${#ordered[@]}" -eq 0 ]; then
    echo "no named workspaces for output $output" >&2
    exit 1
fi

# Find current named index; a blank/unnamed workspace is treated as a boundary.
idx=""
for i in "${!ordered[@]}"; do
    if [ "${ordered[$i]}" = "$current" ]; then
        idx=$i
    fi
done

n=${#ordered[@]}
if [ -z "$idx" ]; then
    if [ "$dir" = "next" ]; then
        target=0
    else
        target=$((n - 1))
    fi
else
    idx=$((idx))
    if [ "$dir" = "next" ]; then
        target=$(( (idx + 1) % n ))
    else
        target=$(( (idx - 1 + n) % n ))
    fi
fi

target_name="${ordered[$target]}"

if [ "$op" = "move" ]; then
    niri msg action move-column-to-workspace "$target_name"
    niri msg action move-column-to-index 1
else
    niri msg action focus-workspace "$target_name"
    niri msg action focus-column 1
fi