#!/bin/bash
# niri-column-move.sh
# Move column at index N to column 1 (master) and focus it
# Usage: niri-column-move.sh <column-index>

set -euo pipefail

index="${1:-}"

if [ -z "$index" ]; then
  echo "usage: niri-column-move.sh <column-index>" >&2
  exit 1
fi

# Focus the desired column, then move it to master (column 1)
niri msg action focus-column "$index"
niri msg action move-column-to-index 1
