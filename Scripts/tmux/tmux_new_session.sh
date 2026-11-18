#!/bin/zsh

preprocess_session_name() {
    user=$(whoami)
    echo "$1" | sed \
        -e "s|/home/${user}|~|g" \
        -e "s|/run/media/${user}/ExternalSSD/code|code|g" \
        -e "s|\.||g" 
}


session_path=$1
session_path_escaped="$(preprocess_session_name "$session_path")"

existing_sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null)
session_name=""
for i in {1..99}; do
    candidate="$(echo "$session_path_escaped" | sed "s|^$HOME|~|")-$i"
    if ! echo "$existing_sessions" | grep -q "^$candidate$"; then
        session_name="$candidate"
        break
    fi
done

if [[ -z "$session_name" ]]; then
    echo "Error: all 99 session-name suffixes for '$session_path_escaped' are taken" >&2
    exit 1
fi

tmux display-message "$session_name"
tmux new-session -s "$session_name" -d -c "$session_path"
tmux switch-client -t "$session_name" 
