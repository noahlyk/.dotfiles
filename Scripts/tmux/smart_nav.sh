#!/bin/bash
# Alt+arrows: move between panes. Inside vim/nvim/fzf the key is passed through so
# vim can move between its own splits. Windows and sessions have their own Alt binds.
# Usage: smart_nav.sh left|right|up|down

pane_tty=$(tmux display -p '#{pane_tty}')
if ps -o state= -o comm= -t "$pane_tty" | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|l?n?vim?x?|fzf)(diff)?$'; then
    case "$1" in
        left)  tmux send-keys M-Left ;;
        right) tmux send-keys M-Right ;;
        up)    tmux send-keys M-Up ;;
        down)  tmux send-keys M-Down ;;
    esac
    exit 0
fi

case "$1" in
    left)  tmux select-pane -L ;;
    right) tmux select-pane -R ;;
    up)    tmux select-pane -U ;;
    down)  tmux select-pane -D ;;
esac
exit 0
