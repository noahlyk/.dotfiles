#!/bin/bash

# Smart navigation script for tmux
# Usage: ./smart_nav.sh left|right|up|down

DIRECTION="$1"

# Check if current pane is running vim
pane_tty=$(tmux display -p '#{pane_tty}')
if ps -o state= -o comm= -t "$pane_tty" | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|l?n?vim?x?|fzf)(diff)?$'; then
    case "$DIRECTION" in
        left)   tmux send-keys M-Left ;;
        right)  tmux send-keys M-Right ;;
        up)     tmux send-keys M-Up ;;
        down)   tmux send-keys M-Down ;;
    esac
    exit 0
fi
cur_win=$(tmux display -p "#{window_index}")
last_win=$(tmux display -p "#{session_windows}")

if [ "$DIRECTION" = "left" ]; then
    at_edge=$(tmux display -p "#{pane_at_left}")
    if [ "$at_edge" = "1" ]; then
        prev_win=$(tmux list-windows | awk -F: '$1 < cur_win { print $1 }' cur_win="$cur_win" | sort -nr | head -1)
        if [ -n "$prev_win" ]; then
            tmux select-window -t "$prev_win"
        fi
    elif [ "$at_edge" = "0" ]; then
        tmux select-pane -L
    fi
elif [ "$DIRECTION" = "right" ]; then
    at_edge=$(tmux display -p "#{pane_at_right}")
    if [ "$at_edge" = "1" ]; then
        next_win=$(tmux list-windows | awk -F: '$1 > cur_win { print $1 }' cur_win="$cur_win" | sort -n | head -1)
        if [ -n "$next_win" ]; then
            tmux select-window -t "$next_win"
        fi
    elif [ "$at_edge" = "0" ]; then
        tmux select-pane -R
    fi
elif [ "$DIRECTION" = "up" ]; then
    at_edge=$(tmux display -p "#{pane_at_top}")
    if [ "$at_edge" = "1" ]; then
        ~/.config/tmux/scripts/tmux_sessions.sh prev
    elif [ "$at_edge" = "0" ]; then
        tmux select-pane -U
    fi
elif [ "$DIRECTION" = "down" ]; then
    at_edge=$(tmux display -p "#{pane_at_bottom}")
    if [ "$at_edge" = "1" ]; then
        ~/.config/tmux/scripts/tmux_sessions.sh down
    elif [ "$at_edge" = "0" ]; then
        tmux select-pane -D
    fi
fi

exit 0