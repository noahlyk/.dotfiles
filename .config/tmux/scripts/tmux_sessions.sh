#!/bin/bash

# Combined session index/info functionality
# Usage: ./tmux_sessions.sh [current|total|next|prev|list|info]

get_current_session_index() {
    local attached=$(tmux display -p "#{session_name}")
    local index=0
    while IFS= read -r line; do
        local session_name=$(echo "$line" | awk '{print $2}')
        if [ "$session_name" = "$attached" ]; then
            echo $index
            return
        fi
        ((index++))
    done < <(tmux list-sessions -F "#{session_created} #{session_name} #{session_windows}" | sort -n)
}

get_session_name() {
    local target_index=$1
    local index=0
    while IFS= read -r line; do
        if [ "$index" -eq "$target_index" ]; then
            echo "$line" | awk '{print $2}'
            return
        fi
        ((index++))
    done < <(tmux list-sessions -F "#{session_created} #{session_name} #{session_windows}" | sort -n)
}

get_total_sessions() {
    tmux list-sessions | wc -l
}

case "$1" in
    "current")
        # Return 1-based index for status line
        current_index=$(get_current_session_index)
        echo $((current_index + 1))
        ;;
    "total")
        get_total_sessions
        ;;
    "update-index")
        # Writes "N/total" into each session's own @session_index_text option instead of
        # computing it live via a #() job in the status line: a #() job that itself calls
        # back into `tmux` (as get_current_session_index/get_total_sessions do) reliably
        # comes back empty when tmux is running it as part of evaluating its own status
        # format -- the job's `tmux` call can't get a response until that same redraw
        # finishes, so it stalls forever. Recomputing here and setting a plain option
        # (which the bar just reads, no job involved) sidesteps that entirely. Bound to
        # session-created / session-closed / client-session-changed hooks and run once at
        # config load, so every session's value stays current.
        total=$(get_total_sessions)
        index=0
        while IFS= read -r line; do
            session_name=$(echo "$line" | awk '{print $2}')
            tmux set -t "$session_name" @session_index_text "$((index + 1))/$total"
            ((index++))
        done < <(tmux list-sessions -F "#{session_created} #{session_name} #{session_windows}" | sort -n)
        exit 0
        ;;
    "list"|"info")
        index=0
        attached_session=$(tmux display -p "#{session_name}")
        while IFS= read -r line; do
            session_name=$(echo "$line" | awk '{print $2}')
            window_count=$(echo "$line" | awk '{print $3}')
            if [ "$session_name" = "$attached_session" ]; then
                printf "(%d) + %s: %s windows (attached)\n" "$index" "$session_name" "$window_count"
            else
                printf "(%d) + %s: %s windows\n" "$index" "$session_name" "$window_count"
            fi
            ((index++))
        done < <(tmux list-sessions -F "#{session_created} #{session_name} #{session_windows}" | sort -n)
        ;;
    "next")
        current=$(get_current_session_index)
        total=$(get_total_sessions)
        if [ "$current" -lt "$((total - 1))" ]; then
            target_index=$((current + 1))
            session_name=$(get_session_name $target_index)
            if [ "$session_name" = "~" ]; then
                tmux switch-client -t "\\~"
            elif [ -n "$session_name" ]; then
                tmux switch-client -t "$session_name"
            fi
        fi
        ;;
    "prev")
        current=$(get_current_session_index)
        if [ "$current" -gt 0 ]; then
            target_index=$((current - 1))
            session_name=$(get_session_name $target_index)
            if [ "$session_name" = "~" ]; then
                tmux switch-client -t "\\~"
            elif [ -n "$session_name" ]; then
                tmux switch-client -t "$session_name"
            fi
        fi
        ;;
    "down")
        current=$(get_current_session_index)
        total=$(get_total_sessions)
        if [ "$current" -lt "$((total - 1))" ]; then
            target_index=$((current + 1))
            session_name=$(get_session_name $target_index)
            if [ "$session_name" = "~" ]; then
                tmux switch-client -t "\\~"
            elif [ -n "$session_name" ]; then
                tmux switch-client -t "$session_name"
            fi
        fi
        ;;
    *)
        echo "Usage: $0 [current|total|next|prev|list|info]"
        exit 1
        ;;
esac