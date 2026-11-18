#!/bin/bash

WINDOW_CLASS="hypr-fastfetch"

get_window_address() {
    hyprctl clients -j | jq -r ".[] | select(.class == \"$WINDOW_CLASS\") | .address" | head -n1
}

WINDOW_ADDRESS=$(get_window_address)

if [[ -n "$WINDOW_ADDRESS" ]]; then
    hyprctl dispatch closewindow "address:$WINDOW_ADDRESS" 2>/dev/null
else
    kitty --class "$WINDOW_CLASS" --config ~/.config/kitty/fastfetch.conf \
        -e zsh -c "tput civis; fastfetch; \
        while true; do IFS= read -rs -k1 key; \
        case \"\$key\" in \
            t) notify-send 'lol hi' ;; \
            c) fastfetch --logo none | dms cl copy && notify-send 'Copied to Clipboard' ;; \
            q|$'\n'|$'\x03') kitty @ close-window --self; exit ;; \
        esac; \
        done; tput cnorm" &
fi
