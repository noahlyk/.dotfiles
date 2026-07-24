#!/usr/bin/env bash
#
# git-linearize.sh — collapse N sibling feature branches into ONE straight line
#                    on top of a base branch (default: dev).
#
# The problem: you have 5 branches all forked off `dev`. That's a fan:
#
#         /-- feat-a
#        /--- feat-b
#   dev ----- feat-c
#        \--- feat-d
#         \-- feat-e
#
# You want a train, in an order you choose:
#
#   dev - [feat-a] - [feat-b] - [feat-c] - [feat-d] - [feat-e]
#                                                        ^ dev fast-forwards here
#
# The trick is that each branch is rebased onto the PREVIOUS FEATURE BRANCH,
# not back onto dev. By the time the last one is rebased the whole chain is
# already a single unbroken line, so `dev` only has to fast-forward once, at
# the end. (A `--ff-only` merge is used precisely so a stray merge commit can
# never sneak in and un-linearize the result.)
#
# Flow:
#   1. pick    fzf multi-select, branches sorted by last commit (newest first),
#              with a preview of each branch's unique commits. SPACE toggles.
#   2. order   a small keyboard TUI: j/k to move the cursor, J/K to move the
#              branch, d to drop, r to reverse, e to bail out to $EDITOR.
#   3. confirm the exact commands + any force-push warnings, then y/N.
#   4. run     rebase the chain, fast-forward the base.
#
# Safety:
#   * Every affected branch's SHA is recorded BEFORE anything moves, so
#     `--undo` puts the world back exactly as it was.
#   * A dirty working tree, a rebase already in progress, or an unknown branch
#     aborts before the first write.
#   * A conflict pauses the run and saves state — resolve it, `git rebase
#     --continue`, then `git-linearize.sh --continue` picks the chain back up.
#
# Usage:
#   git-linearize.sh [BRANCH...] [-b BASE] [-n] [-d] [-u] [-y]
#   git-linearize.sh --continue | --abort | --undo
#
# Options:
#   -b, --base BRANCH   base to stack onto      (default: dev/develop/main/master)
#   -n, --dry-run       print the commands, change nothing
#   -d, --delete        delete the feature branches once they're folded in
#   -u, --update-base   fetch + fast-forward the base from its upstream first
#   -y, --yes           skip the final confirmation
#       --continue      resume a run that stopped on a conflict
#       --abort         abort a stopped run (aborts the rebase, restores HEAD)
#       --undo          reset every touched branch to its pre-run SHA
#   -h, --help          this text
#
# Passing BRANCH names positionally skips both the picker and the reorderer —
# the order you type is the order you get.
#
# Requires: git, fzf (only for the interactive picker).

set -uo pipefail

# ─── appearance ──────────────────────────────────────────────────────────────
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'; RV=$'\e[7m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'
else
    R=''; B=''; D=''; RV=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''
fi

die()  { printf '%s\n' "${RED}error:${R} $*" >&2; exit 1; }
warn() { printf '%s\n' "${YEL}warn:${R} $*" >&2; }
info() { printf '%s\n' "$*"; }

usage() { sed -n '3,/^# Requires/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#$//'; }

# ─── options ─────────────────────────────────────────────────────────────────
BASE=''
DRY=false
DELETE=false
UPDATE_BASE=false
ASSUME_YES=false
ACTION=run
CLI_BRANCHES=()

while (( $# )); do
    case $1 in
        -b|--base)        BASE=${2:?--base needs a branch}; shift 2 ;;
        -n|--dry-run)     DRY=true; shift ;;
        -d|--delete)      DELETE=true; shift ;;
        -u|--update-base) UPDATE_BASE=true; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        --continue)       ACTION=continue; shift ;;
        --abort)          ACTION=abort; shift ;;
        --undo)           ACTION=undo; shift ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; CLI_BRANCHES+=("$@"); break ;;
        -*)               die "unknown option: $1 (try --help)" ;;
        *)                CLI_BRANCHES+=("$1"); shift ;;
    esac
done

# ─── repo ────────────────────────────────────────────────────────────────────
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
GIT_DIR=$(git rev-parse --absolute-git-dir)
STATE="$GIT_DIR/linearize.state"
UNDO="$GIT_DIR/linearize.undo"

have_branch() { git show-ref --verify --quiet "refs/heads/$1"; }

detect_base() {
    local b
    for b in dev develop main master trunk; do
        have_branch "$b" && { printf '%s' "$b"; return; }
    done
    git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'
}

# Where we should end up if the user aborts: a branch name, or a bare SHA when
# HEAD is detached.
current_head() {
    local b
    b=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) && { printf '%s' "$b"; return; }
    git rev-parse HEAD
}

rebase_in_progress() {
    [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]
}

require_clean() {
    rebase_in_progress && die "a rebase is already in progress — finish it, or run --abort"
    git diff --quiet --ignore-submodules HEAD 2>/dev/null \
        || die "working tree has uncommitted changes — commit or stash them first"
}

# ─── state (survives a conflict pause) ───────────────────────────────────────
save_state() {   # save_state <prev> <todo...>
    local prev=$1; shift
    {
        printf 'base=%s\n'   "$BASE"
        printf 'orig=%s\n'   "$ORIG_HEAD"
        printf 'prev=%s\n'   "$prev"
        printf 'todo=%s\n'   "$*"
        printf 'delete=%s\n' "$DELETE"
        printf 'chain=%s\n'  "${CHAIN[*]}"
    } >"$STATE"
}

load_state() {
    [[ -f $STATE ]] || die "no linearize in progress (no $STATE)"
    local line key val
    while IFS= read -r line; do
        key=${line%%=*}; val=${line#*=}
        case $key in
            base)   BASE=$val ;;
            orig)   ORIG_HEAD=$val ;;
            prev)   PREV=$val ;;
            todo)   read -r -a TODO <<<"$val" ;;
            delete) DELETE=$val ;;
            chain)  read -r -a CHAIN <<<"$val" ;;
        esac
    done <"$STATE"
}

clear_state() { rm -f "$STATE"; }

# ─── undo ledger ─────────────────────────────────────────────────────────────
record_undo() {   # record_undo <branch...>  — snapshot SHAs before we touch anything
    local b sha
    : >"$UNDO"
    for b in "$@"; do
        sha=$(git rev-parse --verify --quiet "refs/heads/$b") || continue
        printf '%s %s\n' "$b" "$sha" >>"$UNDO"
    done
}

do_undo() {
    [[ -f $UNDO ]] || die "nothing to undo (no $UNDO)"
    rebase_in_progress && die "a rebase is in progress — run --abort first"
    local cur b sha n=0
    cur=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    while read -r b sha; do
        [[ -n $b ]] || continue
        if [[ $b == "$cur" ]]; then
            git diff --quiet --ignore-submodules HEAD 2>/dev/null \
                || die "working tree is dirty on $b — cannot reset it"
            git reset --hard "$sha" >/dev/null
        else
            git update-ref "refs/heads/$b" "$sha"
        fi
        printf '  %s%s%s -> %s\n' "$CYN" "$b" "$R" "${sha:0:9}"
        n=$((n+1))
    done <"$UNDO"
    rm -f "$UNDO"; clear_state
    info "${GRN}restored $n branch(es).${R}"
}

# ─── branch inventory ────────────────────────────────────────────────────────
# CAND[i]="name<TAB>ahead<TAB>behind<TAB>reldate<TAB>subject"
collect_candidates() {
    local name reldate subject counts behind ahead
    CAND=()
    while IFS=$'\t' read -r name reldate subject; do
        [[ $name == "$BASE" ]] && continue
        counts=$(git rev-list --left-right --count "$BASE...$name" 2>/dev/null) || continue
        behind=${counts%%[[:space:]]*}
        ahead=${counts##*[[:space:]]}
        (( ahead > 0 )) || continue          # nothing unique to stack — skip
        CAND+=("$name"$'\t'"$ahead"$'\t'"$behind"$'\t'"$reldate"$'\t'"$subject")
    done < <(git for-each-ref --sort=-committerdate refs/heads/ \
                 --format='%(refname:short)%09%(committerdate:relative)%09%(contents:subject)')
}

# ─── step 1: pick ────────────────────────────────────────────────────────────
pick_branches() {
    command -v fzf >/dev/null || die "fzf not found — pass branch names as arguments instead"

    local w=0 e name ahead behind reldate subject
    for e in "${CAND[@]}"; do
        name=${e%%$'\t'*}
        (( ${#name} > w )) && w=${#name}
    done

    local -a lines=()
    for e in "${CAND[@]}"; do
        IFS=$'\t' read -r name ahead behind reldate subject <<<"$e"
        lines+=("$(printf '%-*s  %s%3d↑%s %s%3d↓%s  %s%-16s%s %s%.60s%s' \
            "$w" "$name" \
            "$GRN" "$ahead" "$R" \
            "$D" "$behind" "$R" \
            "$MAG" "$reldate" "$R" \
            "$D" "$subject" "$R")")
    done

    printf '%s\n' "${lines[@]}" | fzf \
        --multi --ansi --reverse --height=90% --border=rounded \
        --prompt='linearize ❯ ' --pointer='▸' --marker='✓' \
        --header-first \
        --header=$'SPACE toggle · TAB toggle+down · CTRL-A all · ENTER confirm · ESC cancel\nsorted by last commit, newest first — ↑ commits ahead of '"$BASE"$', ↓ behind\n' \
        --bind='space:toggle,tab:toggle+down,ctrl-a:toggle-all,ctrl-d:deselect-all,?:toggle-preview' \
        --preview="git log --color=always --oneline --no-decorate '$BASE'..{1} | head -200" \
        --preview-window='right,50%,border-left' \
        | sed 's/\x1b\[[0-9;]*m//g' | awk 'NF{print $1}'
}

# ─── step 2: reorder ─────────────────────────────────────────────────────────
TUI_ON=false
tui_cleanup() {
    $TUI_ON || return 0
    TUI_ON=false
    { tput cnorm; tput rmcup; } >/dev/tty 2>/dev/null || true
    stty echo </dev/tty >/dev/null 2>&1 || true
}
trap 'tui_cleanup' EXIT
trap 'tui_cleanup; exit 130' INT TERM

# Reads one keypress (including arrow escape sequences) into KEY.
read_key() {
    local k='' rest=''
    IFS= read -rsn1 k <&3 || return 1
    if [[ $k == $'\e' ]]; then
        IFS= read -rsn2 -t 0.03 rest <&3 || true
        k+=$rest
    fi
    KEY=$k
}

# Fills ORDER[] with the branch names in the chosen order. Returns 1 on cancel.
reorder_tui() {
    local -a items=("$@")
    local n=${#items[@]} cur=0 w=0 i nm ahead tmp

    for i in "${items[@]}"; do nm=${i%%$'\t'*}; (( ${#nm} > w )) && w=${#nm}; done

    exec 3</dev/tty
    TUI_ON=true
    { tput smcup; tput civis; } >/dev/tty 2>/dev/null || true

    while :; do
        {
            printf '\e[H\e[2J'
            printf '%s  order the chain%s  %s— top is rebased onto %s first%s\n\n' \
                   "$B" "$R" "$D" "$BASE" "$R"
            printf '   %s%s%s\n' "$D" "$BASE" "$R"
            for ((i = 0; i < n; i++)); do
                IFS=$'\t' read -r nm ahead <<<"${items[i]}"
                if (( i == cur )); then
                    printf '%s ▸ %2d  %-*s %s%s commits%s\n' \
                        "$CYN" $((i+1)) "$w" "$nm" "$R$D" "$ahead" "$R"
                else
                    printf '   %s%2d%s  %-*s %s%s commits%s\n' \
                        "$D" $((i+1)) "$R" "$w" "$nm" "$D" "$ahead" "$R"
                fi
            done
            printf '\n   %s%s fast-forwards to %s%s\n\n' \
                   "$D" "$BASE" "$(printf '%s' "${items[n-1]%%$'\t'*}")" "$R"
            printf '%s  j/k move cursor · J/K move branch · d drop · r reverse · e $EDITOR\n' "$D"
            printf '  ENTER accept · q cancel%s\n' "$R"
        } >/dev/tty

        read_key || break
        case $KEY in
            ''|$'\n'|$'\r')  break ;;
            j|$'\e[B')  if (( cur < n-1 )); then cur=$((cur+1)); fi ;;
            k|$'\e[A')  if (( cur > 0 ));   then cur=$((cur-1)); fi ;;
            J)  if (( cur < n-1 )); then
                    tmp=${items[cur]}; items[cur]=${items[cur+1]}; items[cur+1]=$tmp
                    cur=$((cur+1))
                fi ;;
            K)  if (( cur > 0 )); then
                    tmp=${items[cur]}; items[cur]=${items[cur-1]}; items[cur-1]=$tmp
                    cur=$((cur-1))
                fi ;;
            g)  cur=0 ;;
            G)  cur=$((n-1)) ;;
            d|x)
                if (( n > 1 )); then
                    items=("${items[@]:0:cur}" "${items[@]:cur+1}")
                    n=$((n-1))
                    if (( cur >= n )); then cur=$((n-1)); fi
                fi ;;
            r)  local -a rev=()
                for ((i = n-1; i >= 0; i--)); do rev+=("${items[i]}"); done
                items=("${rev[@]}"); cur=$((n-1-cur)) ;;
            e)  local f; f=$(mktemp)
                {
                    for i in "${items[@]}"; do
                        IFS=$'\t' read -r nm ahead <<<"$i"
                        printf '%s\t# %s commits\n' "$nm" "$ahead"
                    done
                    printf '\n# reorder / delete lines, then save and quit.\n'
                    printf '# top of the list is rebased onto %s first.\n' "$BASE"
                } >"$f"
                tui_cleanup
                "${EDITOR:-vi}" "$f" </dev/tty >/dev/tty 2>&1 || true
                local -a kept=() line pick
                while IFS= read -r line; do
                    line=${line%%#*}
                    pick=$(printf '%s' "$line" | awk 'NF{print $1}')
                    [[ -n $pick ]] || continue
                    for i in "${items[@]}"; do
                        [[ ${i%%$'\t'*} == "$pick" ]] && kept+=("$i") && break
                    done
                done <"$f"
                rm -f "$f"
                if (( ${#kept[@]} )); then items=("${kept[@]}"); n=${#items[@]}; cur=0; fi
                TUI_ON=true
                { tput smcup; tput civis; } >/dev/tty 2>/dev/null || true ;;
            q|$'\e')
                tui_cleanup; exec 3<&-; return 1 ;;
        esac
    done

    tui_cleanup
    exec 3<&-
    ORDER=()
    for i in "${items[@]}"; do ORDER+=("${i%%$'\t'*}"); done
    return 0
}

# ─── step 3: confirm ─────────────────────────────────────────────────────────
show_plan() {
    local i b n_total=0 ahead prev=$BASE up
    printf '\n%splan%s  %s(%s @ %s)%s\n\n' "$B" "$R" "$D" "$BASE" \
           "$(git rev-parse --short "$BASE")" "$R"
    printf '   %s%s%s\n' "$BLU" "$BASE" "$R"
    for i in "${!CHAIN[@]}"; do
        b=${CHAIN[i]}
        ahead=${AHEAD[$b]}
        n_total=$((n_total + ahead))
        if (( i == ${#CHAIN[@]} - 1 )); then printf '   └─ '; else printf '   ├─ '; fi
        printf '%s%-24s%s %s%s commits%s  %sonto %s%s\n' \
               "$CYN" "$b" "$R" "$D" "$ahead" "$R" "$D" "$prev" "$R"
        prev=$b
    done
    printf '\n   %s%s%s fast-forwards to %s%s%s  %s(+%s commits, one straight line)%s\n' \
           "$BLU" "$BASE" "$R" "$CYN" "${CHAIN[-1]}" "$R" "$D" "$n_total" "$R"

    printf '\n%scommands%s\n' "$B" "$R"
    prev=$BASE
    for b in "${CHAIN[@]}"; do
        printf '   %sgit checkout %s && git rebase %s%s\n' "$D" "$b" "$prev" "$R"
        prev=$b
    done
    printf '   %sgit checkout %s && git merge --ff-only %s%s\n' "$D" "$BASE" "${CHAIN[-1]}" "$R"
    $DELETE && printf '   %sgit branch -d %s%s\n' "$D" "${CHAIN[*]}" "$R"

    # Only *remote* upstreams matter here — a branch that merely tracks a local
    # branch (git's default when you branch off dev) needs no force-push.
    local -a pushed=()
    for b in "${CHAIN[@]}"; do
        up=$(git rev-parse --symbolic-full-name "$b@{u}" 2>/dev/null) || continue
        [[ $up == refs/remotes/* ]] && pushed+=("$b → ${up#refs/remotes/}")
    done
    if (( ${#pushed[@]} )); then
        printf '\n%swarning%s  rewriting history on branches that have upstreams —\n' "$YEL" "$R"
        printf '         they will need %sgit push --force-with-lease%s afterwards:\n' "$B" "$R"
        for b in "${pushed[@]}"; do printf '           %s%s%s\n' "$D" "$b" "$R"; done
    fi
    printf '\n'
}

confirm() {
    $ASSUME_YES && return 0
    local reply
    printf '%sproceed?%s [y/N] ' "$B" "$R"
    read -r reply </dev/tty || return 1
    [[ $reply == [yY]* ]]
}

# ─── step 4: execute ─────────────────────────────────────────────────────────
run_cmd() {
    printf '%s+ %s%s\n' "$D" "$*" "$R"
    $DRY && return 0
    "$@"
}

# Rebase everything still in TODO onto PREV, saving state as we go.
run_chain() {
    local b
    while (( ${#TODO[@]} )); do
        b=${TODO[0]}
        printf '\n%s▸ %s%s %sonto %s%s\n' "$B$CYN" "$b" "$R" "$D" "$PREV" "$R"
        if ! run_cmd git checkout --quiet "$b"; then
            save_state "$PREV" "${TODO[@]}"
            die "could not check out $b"
        fi
        if ! run_cmd git rebase "$PREV"; then
            save_state "$PREV" "${TODO[@]}"
            printf '\n%sconflict while rebasing %s onto %s.%s\n' "$YEL" "$b" "$PREV" "$R"
            printf '  resolve it, %sgit add%s the files, then %sgit rebase --continue%s\n' "$B" "$R" "$B" "$R"
            printf '  when the rebase finishes, resume the chain with:\n'
            printf '      %s%s --continue%s\n' "$B" "$0" "$R"
            printf '  or throw the whole thing away with:\n'
            printf '      %s%s --abort%s\n' "$B" "$0" "$R"
            exit 2
        fi
        PREV=$b
        TODO=("${TODO[@]:1}")
        save_state "$PREV" ${TODO[@]+"${TODO[@]}"}
    done

    printf '\n%s▸ fast-forwarding %s%s\n' "$B$BLU" "$BASE" "$R"
    run_cmd git checkout --quiet "$BASE" || die "could not check out $BASE"
    if ! run_cmd git merge --ff-only "$PREV"; then
        die "$BASE could not fast-forward to $PREV — it must have moved; rerun with --update-base"
    fi

    if [[ $DELETE == true ]]; then
        local b2
        for b2 in "${CHAIN[@]}"; do
            [[ $b2 == "$BASE" ]] && continue
            run_cmd git branch -d "$b2" || warn "kept $b2 (not fully merged?)"
        done
    fi

    clear_state

    if $DRY; then
        printf '\n%s✓ dry run%s — nothing was changed.\n\n' "$YEL" "$R"
        return 0
    fi

    local total
    total=$(git rev-list --count "$ORIG_BASE_SHA..$BASE")
    printf '\n%s✓ linearized%s  %s%s%s  %s → %s%s  %s(%d branches, +%d commits, one straight line)%s\n' \
           "$GRN" "$R" "$BLU" "$BASE" "$R" \
           "${ORIG_BASE_SHA:0:9}" "$(git rev-parse --short "$BASE")" "$R" \
           "$D" "${#CHAIN[@]}" "$total" "$R"
    printf '  %sundo everything:%s %s --undo\n\n' "$D" "$R" "$0"
    git --no-pager log --oneline --graph --decorate -n "$(( total + 3 ))" "$BASE" 2>/dev/null || true
}

# ─── entry points ────────────────────────────────────────────────────────────
case $ACTION in
undo)
    do_undo
    exit 0
    ;;
abort)
    if rebase_in_progress; then git rebase --abort || true; fi
    if [[ -f $STATE ]]; then
        load_state
        git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true
    fi
    clear_state
    info "aborted. branches left as they are — run ${B}$0 --undo${R} to rewind them too."
    exit 0
    ;;
continue)
    load_state
    rebase_in_progress && die "the rebase is still unresolved — finish it (git rebase --continue) or run --abort"
    ORIG_BASE_SHA=$(git rev-parse "$BASE")
    declare -A AHEAD=()
    if (( ${#TODO[@]} == 0 )); then
        info "nothing left to rebase — finishing up."
    else
        info "resuming: ${CYN}${TODO[*]}${R}"
    fi
    run_chain
    exit 0
    ;;
esac

# ── fresh run ────────────────────────────────────────────────────────────────
[[ -n $BASE ]] || BASE=$(detect_base)
[[ -n $BASE ]] || die "could not work out a base branch — pass --base"
have_branch "$BASE" || die "base branch '$BASE' does not exist"

require_clean

if $UPDATE_BASE; then
    info "updating ${BLU}$BASE${R} from its upstream…"
    run_cmd git fetch --quiet --prune || warn "fetch failed, carrying on with the local $BASE"
    if git rev-parse --verify --quiet "$BASE@{u}" >/dev/null; then
        run_cmd git checkout --quiet "$BASE" || die "could not check out $BASE"
        run_cmd git merge --ff-only "$BASE@{u}" || die "$BASE cannot fast-forward to its upstream"
    else
        warn "$BASE has no upstream — skipping"
    fi
fi

ORIG_HEAD=$(current_head)
ORIG_BASE_SHA=$(git rev-parse "$BASE")

declare -a CHAIN=()
declare -A AHEAD=()

if (( ${#CLI_BRANCHES[@]} )); then
    # Non-interactive: the argument order IS the chain order.
    for b in "${CLI_BRANCHES[@]}"; do
        have_branch "$b" || die "no such branch: $b"
        [[ $b == "$BASE" ]] && die "'$b' is the base branch"
        CHAIN+=("$b")
    done
else
    collect_candidates
    (( ${#CAND[@]} )) || die "no branches with commits of their own on top of '$BASE'"

    mapfile -t picked < <(pick_branches)
    (( ${#picked[@]} )) || { info "nothing selected."; exit 0; }

    # Hand the picker's output to the reorderer, newest-first as it came in.
    declare -a items=()
    for b in "${picked[@]}"; do
        for e in "${CAND[@]}"; do
            if [[ ${e%%$'\t'*} == "$b" ]]; then
                IFS=$'\t' read -r nm ah rest <<<"$e"
                items+=("$nm"$'\t'"$ah")
                break
            fi
        done
    done

    declare -a ORDER=()
    if (( ${#items[@]} > 1 )); then
        reorder_tui "${items[@]}" || { info "cancelled."; exit 0; }
    else
        ORDER=("${items[0]%%$'\t'*}")
    fi
    CHAIN=("${ORDER[@]}")
fi

(( ${#CHAIN[@]} )) || { info "nothing to do."; exit 0; }

for b in "${CHAIN[@]}"; do
    AHEAD[$b]=$(git rev-list --count "$BASE..$b")
done

show_plan
confirm || { info "cancelled."; exit 0; }

$DRY || record_undo "$BASE" "${CHAIN[@]}"
PREV=$BASE
TODO=("${CHAIN[@]}")
run_chain
