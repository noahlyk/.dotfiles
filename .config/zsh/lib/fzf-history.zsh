# vim: ft=zsh
# fzf Ctrl-R history picker; ctrl-x deletes the hovered entry from history for good

if (( $+commands[fzf] )); then
    # Drop every entry listed in $1 (NUL-separated) from $HISTFILE and memory.
    # Entries can span lines: zsh stores a newline inside an entry as "\<newline>",
    # so a record is a ": <ts>:<dur>;" header line plus any continuation lines.
    __fzf_history_purge() {
        emulate -L zsh
        [[ -s $1 && -f $HISTFILE ]] || return 0
        local tmp=$(mktemp)
        awk -v delf="$1" '
            function flush() { if (rec != "" && !(txt in del)) printf "%s", rec; rec = "" }
            BEGIN { RS = "\0"; while ((getline e < delf) > 0) del[e]; close(delf); RS = "\n" }
            {
                if (cont) { txt = substr(txt, 1, length(txt) - 1) "\n" $0; rec = rec $0 "\n" }
                else      { flush(); txt = $0; sub(/^: [0-9]+:[0-9]+;/, "", txt); rec = $0 "\n" }
                cont = ($0 ~ /\\$/)
            }
            END { flush() }' "$HISTFILE" > $tmp &&
            cat $tmp > $HISTFILE   # cat keeps the 600 perms
        command rm -f $tmp
        # Reload so the deleted entries are gone from this session too
        local size=$HISTSIZE
        HISTSIZE=0; HISTSIZE=$size
        fc -R
    }

    __fzf_history__() {
        local selected list del k
        list=$(mktemp) del=$(mktemp)
        # One NUL-separated record per entry (multiline commands stay whole),
        # newest first, deduped keeping the newest
        for k in ${(kOn)history}; do print -rN -- $history[$k]; done |
            awk -v RS='\0' -v ORS='\0' '!seen[$0]++' > $list
        # ctrl-x: record the hovered entry for deletion and hide it from the list
        selected=$(fzf --read0 --no-sort --exact --query="$LBUFFER" < $list \
                --height=60% --layout=reverse --border=rounded --info=inline \
                --prompt='  ' --pointer='▶' --color='pointer:cyan,prompt:cyan' \
                --preview='echo {}' --preview-window='down:3:wrap:hidden' \
                --bind='ctrl-/:toggle-preview,ctrl-y:accept' \
                --bind="ctrl-x:execute-silent(printf '%s\0' {} >> $del)+reload(awk -v RS='\0' -v ORS='\0' 'FILENAME==ARGV[1]{d[\$0];next} !(\$0 in d)' $del $list)")
        __fzf_history_purge $del
        command rm -f $list $del
        [[ -n $selected ]] && LBUFFER=$selected
        zle reset-prompt
    }
    zle -N __fzf_history__
    bindkey '^r' __fzf_history__
fi
