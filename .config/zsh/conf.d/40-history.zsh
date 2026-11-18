# vim: ft=zsh
# History

HISTFILE="${XDG_STATE_HOME}/zsh/history"
HISTSIZE=50000
SAVEHIST=50000                  # persist as much as we keep in memory
setopt appendhistory share_history
setopt extended_history        # record timestamp + duration per entry
setopt hist_no_store           # don't save history/fc invocations themselves
setopt hist_expire_dups_first  # Expire duplicates first
setopt hist_ignore_dups        # Ignore consecutive duplicates
setopt hist_ignore_all_dups    # Ignore all duplicates in history
setopt hist_ignore_space       # Ignore commands starting with space
setopt hist_find_no_dups       # Don't show duplicates when searching
setopt hist_reduce_blanks      # Remove extra blanks
setopt hist_verify             # Verify history expansion

# Keep noise out of history. Prefix any command with a space to skip it
# ad-hoc (hist_ignore_space). HISTORY_IGNORE is exact-match noise only; secrets
# are caught by the zshaddhistory hook below, which covers in-memory history too.
HISTORY_IGNORE='(ls|ll|ld|lt|l|cd|cd ..|..|...|.3|.4|.5|pwd|clear|exit|c|v|history|fg|bg|z *)'

# Credential-looking commands never reach history. Case-insensitive, whole line.
zshaddhistory() {
    emulate -L zsh
    setopt extendedglob
    local cmd=${1%%$'\n'}
    [[ $cmd == (#i)*(api_key|apikey|api-key|secret|passwd|password|token=|--token|_key=|authorization:)* ]] && return 1
    [[ $cmd == ${~HISTORY_IGNORE} ]] && return 1
    return 0
}





