#!/bin/bash
# niri-column-toggle.sh
#
# Master-column toggle.
#
# If the focused window is in column 1, move that column to the end of the
# workspace and focus the new first column.
# Otherwise, move the focused column to index 1 (make it the master column).
#
# Skips harmlessly when the workspace has a single column (col 1 is also the
# last column, so move-column-to-last is a no-op and focus-column 1 is already
# focused).

set -euo pipefail

col=$(niri msg -j focused-window | jq -r '.layout.pos_in_scrolling_layout[0]')

if [ "$col" = "1" ]; then
    niri msg action move-column-to-last
    niri msg action focus-column 1
else
    niri msg action move-column-to-index 1
fi