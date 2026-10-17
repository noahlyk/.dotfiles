#!/bin/bash
# Focus the first window that is requesting attention (urgent), switching to
# its workspace. No-op if nothing is urgent.
id=$(niri msg -j windows | jq -r '[.[] | select(.is_urgent)] | .[0].id // empty')
[ -n "$id" ] && niri msg action focus-window --id "$id"
