#!/usr/bin/env bash
# Sets @claude_state (a per-pane tmux option) from Claude Code hook events, so the tmux
# status bar (modules/bar.conf's @claude_marker, in the dotfiles tmux config) can show which
# panes are working / waiting for input / done. Source of truth: ~/Scripts/claude/ (the file
# at ~/.claude/hooks/ is a symlink to it).
set -uo pipefail

MAP_FILE="/home/fib/.claude/hooks/claude-pane-map.tsv"
DEBUG_LOG="/home/fib/.claude/hooks/tmux-claude-state.debug.log"
# keep the diagnostic log from growing without bound
[ "$(stat -c %s "$DEBUG_LOG" 2>/dev/null || echo 0)" -gt 262144 ] && : > "$DEBUG_LOG"

payload=$(cat)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null) || event=""
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null) || transcript_path=""

# Background (daemon) sessions can't be matched to a pane from here, so refresh the session model
# (Scripts/tmux/claude-sessions) on every event that changes state; it asks the daemon. The short
# delay lets the daemon record the new state first. Runs before pane resolution on purpose.
case "$event" in
  SessionStart|UserPromptSubmit|Notification|Stop|SessionEnd)
    setsid -f bash -c 'sleep 0.6; exec "$HOME/Scripts/tmux/claude-sessions" sync --force' >/dev/null 2>&1 < /dev/null
    ;;
esac

# Claude Code's async hook runner only *sometimes* preserves the originating
# session's $TMUX_PANE or controlling tty — confirmed live over several hours:
# the same real panes fired dozens of hook events with neither signal usable,
# then one event would have it correctly, then it would vanish again on the
# very next event for that same session. Neither env var nor tty alone is
# reliable enough on its own.
#
# The fix: cache whichever pane we DO manage to resolve, keyed by the
# payload's session_id (present on every event) in $MAP_FILE. We only need
# to get lucky once per session's lifetime — every later event for that same
# session_id reuses the cached pane even when its own resolution fails.
cache_get() {
  [ -f "$MAP_FILE" ] && [ -n "$session_id" ] || return 1
  awk -F'\t' -v sid="$session_id" '$1 == sid { print $2; found=1 } END { exit !found }' "$MAP_FILE"
}

cache_set() {
  [ -n "$session_id" ] || return 0
  {
    [ -f "$MAP_FILE" ] && awk -F'\t' -v sid="$session_id" '$1 != sid' "$MAP_FILE"
    printf '%s\t%s\n' "$session_id" "$1"
  } > "$MAP_FILE.tmp" 2>/dev/null
  mv "$MAP_FILE.tmp" "$MAP_FILE" 2>/dev/null
}

cache_remove() {
  [ -f "$MAP_FILE" ] && [ -n "$session_id" ] || return 0
  awk -F'\t' -v sid="$session_id" '$1 != sid' "$MAP_FILE" > "$MAP_FILE.tmp" 2>/dev/null
  mv "$MAP_FILE.tmp" "$MAP_FILE" 2>/dev/null
}

# A single ps -o tty= -p "$PPID" lookup only checks the hook script's
# *immediate* parent. Because hooks run with "async": true, that parent is
# often an already-reparented runner process with no real tty (or a stale
# one) by the time this script executes — confirmed in the debug log: real
# ttys turned up but matched no pane (PPID_TTY=pts/9 resolved=1), meaning the
# immediate parent's tty wasn't the originating pane's tty at all. Walk the
# *entire* ancestor chain instead: one of these processes descends from the
# real shell/claude process attached to the pane, so its tty should show up
# somewhere in the chain even if the immediate parent's doesn't.
ancestor_ttys() {
  local pid="$$"
  local depth=0
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 25 ]; do
    local tty
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$tty" ] && [ "$tty" != '?' ] && printf '%s\n' "$tty"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    depth=$((depth + 1))
  done
}

resolve_pane() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  local pane_ttys
  pane_ttys=$(tmux list-panes -a -F '#{pane_tty} #{pane_id}' 2>/dev/null)
  local tty via_tty
  while IFS= read -r tty; do
    [ -n "$tty" ] || continue
    via_tty=$(printf '%s\n' "$pane_ttys" | awk -v tty="/dev/$tty" '$1 == tty { print $2; found=1 } END { exit !found }')
    if [ -n "$via_tty" ]; then
      printf '%s' "$via_tty"
      return 0
    fi
  done < <(ancestor_ttys)
  cache_get
}

# --- temporary diagnostic logging while chasing the resolution bug ---
_debug_ttys=$(ancestor_ttys | tr '\n' ',' )
TARGET_PANE=$(resolve_pane) || {
  printf '%s | event=%s TMUX_PANE=%s ancestor_ttys=%s resolved=NONE session=%s\n' \
    "$(date -Iseconds)" "$event" "${TMUX_PANE:-<unset>}" "${_debug_ttys:-<none>}" "$session_id" >> "$DEBUG_LOG" 2>/dev/null
  exit 0
}
printf '%s | event=%s TMUX_PANE=%s ancestor_ttys=%s resolved_pane=%s session=%s\n' \
  "$(date -Iseconds)" "$event" "${TMUX_PANE:-<unset>}" "${_debug_ttys:-<none>}" "${TARGET_PANE:-<empty>}" "$session_id" >> "$DEBUG_LOG" 2>/dev/null
# --- end temporary diagnostic logging ---

[ -n "$TARGET_PANE" ] || exit 0
cache_set "$TARGET_PANE"

# @claude_state_since (epoch seconds) is when the state last changed; Alt+a and the Alt+g
# dashboard order panes by it (longest-waiting first).
set_state() {
  local previous
  previous=$(tmux show -pqv -t "$TARGET_PANE" @claude_state 2>/dev/null)
  [ "$previous" = "$1" ] || tmux set -p -t "$TARGET_PANE" @claude_state_since "$(date +%s)"
  tmux set -p -t "$TARGET_PANE" @claude_state "$1"
  printf '%s | set_state=%s target=%s exit=%s\n' "$(date -Iseconds)" "$1" "$TARGET_PANE" "$?" >> "$DEBUG_LOG" 2>/dev/null
}

quiet_window() {
  # Claude's TUI redraws constantly; monitor-activity would otherwise spam activity alerts
  # on this window the whole time a session is running in it.
  tmux set -w -t "$TARGET_PANE" monitor-activity off
}

# Per-pane Claude metadata the tmux scripts read: the transcript (for tab naming) and the
# latest prompt (dashboard row). Tab names come from claude-auto-title, run detached once
# per Claude session; set `@claude_auto_title off` in tmux to disable the Haiku call.
claude_tmux_scripts="$HOME/Scripts/tmux"

forget_session_metadata() {
  local option
  for option in @claude_title_auto @claude_title_override @claude_task @claude_transcript @claude_state_since; do
    tmux set -pu -t "$TARGET_PANE" "$option" 2>/dev/null
  done
}

case "$event" in
  SessionStart)
    quiet_window
    forget_session_metadata
    [ -n "$transcript_path" ] && tmux set -p -t "$TARGET_PANE" @claude_transcript "$transcript_path"
    ;;
  UserPromptSubmit|PostToolUse)
    quiet_window
    set_state working
    if [ "$event" = UserPromptSubmit ]; then
      [ -n "$transcript_path" ] && tmux set -p -t "$TARGET_PANE" @claude_transcript "$transcript_path"
      prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //' | cut -c1-120)
      [ -n "$prompt" ] && tmux set -p -t "$TARGET_PANE" @claude_task "$prompt"
      if [ "$(tmux show -gqv @claude_auto_title)" != off ] && [ -x "$claude_tmux_scripts/claude-auto-title" ]; then
        setsid -f "$claude_tmux_scripts/claude-auto-title" "$TARGET_PANE" >/dev/null 2>&1 < /dev/null
      fi
    fi
    ;;
  Notification)
    notification_type=$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null) || notification_type=""
    case "$notification_type" in
      permission_prompt|elicitation_dialog)
        quiet_window
        set_state waiting
        ;;
    esac
    ;;
  Stop)
    quiet_window
    set_state done
    ;;
  SessionEnd)
    tmux set -pu -t "$TARGET_PANE" @claude_state
    forget_session_metadata
    tmux set -wu -t "$TARGET_PANE" monitor-activity
    cache_remove
    ;;
esac

exit 0
