#!/bin/bash
# niri-workspace-go.sh
# Usage:
#   niri-workspace-go.sh focus <workspace-name> [smart]   → focus workspace, land on column 1
#                                                          If "smart" and on different monitor,
#                                                          just switch to that monitor
#   niri-workspace-go.sh move  <workspace-name>           → move focused column to workspace, at column 1

set -euo pipefail

cmd="${1:-}"
ws="${2:-}"
smart="${3:-}"

get_ws_output() {
  local ws_name="$1"
  niri msg -j workspaces | jq -r --arg name "$ws_name" '.[] | select(.name == $name) | .output'
}

case "$cmd" in
  focus)
    if [ "$smart" = "smart" ]; then
      current_output=$(niri msg -j focused-output | jq -r '.name')
      ws_output=$(get_ws_output "$ws")
      
      if [ "$current_output" = "$ws_output" ]; then
        niri msg action focus-workspace "$ws"
        niri msg action focus-column 1
      else
        niri msg action focus-monitor "$ws_output"
      fi
    else
      niri msg action focus-workspace "$ws"
      niri msg action focus-column 1
    fi
    ;;
  move)
    niri msg action move-column-to-workspace "$ws"
    niri msg action move-column-to-index 1
    ;;
  *)
    echo "usage: niri-workspace-go.sh <focus|move> <workspace-name> [smart]" >&2
    exit 1
    ;;
esac