#!/usr/bin/env bash
# mic-mode.sh — read/cycle the crisp-vocals `active_mode` setting.
#
# Usage: mic-mode.sh [get|list|next|prev|set <mode>|json]
#   get        print the current mode (default)
#   list       print all modes defined under `modes: { ... }`, one per line
#   next|prev  cycle to the next/previous mode (wraps around)
#   set <mode> switch to <mode> (must exist in `modes`)
#   json       {"mode": "...", "modes": [...]} for bar widgets
#
# Only the first uncommented `active_mode: "..."` line is rewritten; the rest
# of the file (comments, formatting) is untouched. crisp-vocals hot-reloads.

set -euo pipefail

CONF="${CRISP_VOCALS_CONF:-$HOME/.config/pipewire/crisp-vocals.ron}"

die() { echo "mic-mode: $*" >&2; exit 1; }
[[ -f $CONF ]] || die "config not found: $CONF"

# First uncommented active_mode line -> its value.
current_mode() {
    sed -nE 's/^[[:space:]]*active_mode:[[:space:]]*"([^"]*)".*/\1/p' "$CONF" | head -n1
}

# Keys directly inside `modes: { ... }` (first-level entries only).
list_modes() {
    awk '
        !inmodes && /^[[:space:]]*modes:[[:space:]]*\{/ { inmodes = 1; next }
        inmodes {
            if (match($0, /^[[:space:]]*"[^"]+":[[:space:]]*\(/)) {
                line = substr($0, RSTART, RLENGTH)
                indent = match(line, /[^[:space:]]/) - 1
                if (!depth_indent) depth_indent = indent
                if (indent == depth_indent) {
                    sub(/^[[:space:]]*"/, "", line); sub(/".*/, "", line)
                    print line
                }
            }
            if ($0 ~ /^[[:space:]]*\},?[[:space:]]*$/ && match($0, /[^[:space:]]/) - 1 < depth_indent) exit
        }
    ' "$CONF"
}

set_mode() {
    local new=$1 tmp
    list_modes | grep -qxF -- "$new" || die "unknown mode '$new' (have: $(list_modes | paste -sd' '))"
    tmp=$(mktemp)
    # Rewrite just the first uncommented active_mode line, keep any trailing text.
    awk -v new="$new" '
        !done && /^[[:space:]]*active_mode:[[:space:]]*"/ {
            sub(/"[^"]*"/, "\"" new "\""); done = 1
        }
        { print }
    ' "$CONF" > "$tmp"
    # cat > (not mv) so the inode / symlink / hardlink to the dotfiles stays intact.
    cat "$tmp" > "$CONF"
    rm -f "$tmp"
}

cycle() {
    local step=$1 cur modes n i
    cur=$(current_mode)
    mapfile -t modes < <(list_modes)
    n=${#modes[@]}
    (( n > 0 )) || die "no modes found in $CONF"
    i=0
    for j in "${!modes[@]}"; do [[ ${modes[j]} == "$cur" ]] && i=$j; done
    set_mode "${modes[(i + step + n) % n]}"
    current_mode
}

case "${1:-get}" in
    get)  current_mode ;;
    list) list_modes ;;
    next) cycle 1 ;;
    prev) cycle -1 ;;
    set)  [[ -n ${2:-} ]] || die "usage: $0 set <mode>"; set_mode "$2"; current_mode ;;
    json) printf '{"mode":"%s","modes":[%s]}\n' "$(current_mode)" \
              "$(list_modes | sed 's/.*/"&"/' | paste -sd,)" ;;
    *)    die "usage: $0 [get|list|next|prev|set <mode>|json]" ;;
esac
