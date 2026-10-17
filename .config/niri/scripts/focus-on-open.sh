#!/bin/bash
# focus-on-open.sh
#
# open-on-workspace places a window on another workspace/monitor but niri
# leaves it unfocused there. This watches the niri event stream and focuses
# the first-seen window of the listed apps, which also switches to its
# workspace. Started from spawn-at-startup in config.kdl.

set -u

APPS='^(firefox|org\.keepassxc\.KeePassXC|kitty|com\.obsproject\.Studio)$'

declare -A seen

niri msg -j event-stream | while IFS= read -r line; do
    # Initial snapshot: remember existing windows so they are never refocused.
    while IFS= read -r id; do
        [ -n "$id" ] && seen[$id]=1
    done < <(jq -r '.WindowsChanged.windows[]?.id' <<<"$line" 2>/dev/null)

    read -r id app title < <(jq -r '.WindowOpenedOrChanged.window // empty
        | "\(.id) \(.app_id // "-") \(.title // "-")"' <<<"$line" 2>/dev/null) || continue
    [ -n "${id:-}" ] || continue
    [ -n "${seen[$id]:-}" ] && continue
    [[ "$app" =~ $APPS ]] || continue   # app_id not set yet: stay unseen, retry on next update
    seen[$id]=1
    # The scratch notes window focuses itself.
    [ "$app" = kitty ] && [[ "$title" == "Notes nvim"* ]] && continue
    niri msg action focus-window --id "$id"
done
