# vim: ft=zsh
# Completion

# Completion system
autoload -Uz compinit
local zcd="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
# Ensure the cache dir exists, otherwise compinit can't persist the dump and every
# shell rebuilds completions from scratch (~65ms). With it, the -C fast path below
# actually kicks in (startup ~90ms -> ~25ms).
[[ -d "${zcd:h}" ]] || mkdir -p "${zcd:h}"
[[ -f "$zcd" ]] && compinit -C -d "$zcd" || compinit -d "$zcd"

# Keymux ships its own completion via its package fpath entry; nothing to generate here.

# Completion styling - minimal but functional
zstyle ':completion:*' completer _complete _approximate
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' menu select
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"

# Vi menu navigation
zmodload zsh/complist
bindkey -M menuselect 'h' vi-backward-char
bindkey -M menuselect 'k' vi-up-line-or-history
bindkey -M menuselect 'l' vi-forward-char
bindkey -M menuselect 'j' vi-down-line-or-history

# Enable bash completion compatibility
autoload -Uz bashcompinit
bashcompinit

# install.sh completion
_install() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    opts="local bin --help -h remote"
    
    if [[ ${cur} == * ]] ; then
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
}
complete -F _install install.sh
