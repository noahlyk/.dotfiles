#!/usr/bin/env zsh

# Skip non-interactive shells
[[ -o interactive ]] || return

# Disable gitstatus (must be before instant prompt)
typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true

# Consolidate p10k cache into subdirectory
typeset -g POWERLEVEL9K_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/p10k"

# Enable instant prompt (must be near top)
if [[ -r "$POWERLEVEL9K_CACHE_DIR/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "$POWERLEVEL9K_CACHE_DIR/p10k-instant-prompt-${(%):-%n}.zsh"
fi


export RUSTFLAGS='-W clippy::pedantic -W clippy::nursery -A clippy::unreadable_literal -A clippy::struct_excessive_bools'
export PYENV_ROOT="$XDG_DATA_HOME/pyenv"
export MANPAGER='nvim -c "Man!" -c "set buftype=nofile modifiable"'
export PYENV_VIRTUALENV_DISABLE_PROMPT=1
export LANG=en_US.UTF-8
export EDITOR='nvim'
[[ -n $SSH_CONNECTION ]] && export EDITOR='vim'

path=(
    $HOME/.cargo/bin
    $PYENV_ROOT/bin
    $HOME/.local/bin
    /usr/local/bin
    /usr/local/sbin
    $path
)
export PATH



setopt autocd               # Cd by typing directory name
setopt interactivecomments  # Allow comments in interactive shells
setopt magicequalsubst      # Expand filenames in 'anything=expression'
setopt nonomatch            # Suppress errors on no pattern match
setopt notify               # Report background job status immediately
setopt numericglobsort      # Sort filenames numerically
setopt promptsubst          # Enable command substitution in prompt
setopt auto_pushd           # Push directories to stack
setopt pushd_ignore_dups    # Avoid duplicates in stack
setopt pushd_silent         # Silent pushd/popd
setopt EXTENDED_GLOB        # Enable extended globbing


# Vi Keybindings
bindkey -v                  # Enable vi mode
KEYTIMEOUT=1                # Fast mode switching

# Ensure vi keybindings work in both modes
bindkey '^?' backward-delete-char
bindkey '^H' backward-delete-char
bindkey '^W' backward-kill-word
bindkey '^U' kill-line
bindkey '^Y' yank

autoload edit-command-line
zle -N edit-command-line
bindkey '^e' edit-command-line  # Edit command in editor

# Sudo toggle function
sudo_toggle() {
    if [[ $BUFFER == sudo\ * ]]; then
        BUFFER="${BUFFER#sudo }"
    else
        BUFFER="sudo $BUFFER"
    fi
    zle end-of-line
}
zle -N sudo_toggle
stty -ixon                # free Ctrl+S/Ctrl+Q from XON/XOFF flow control
bindkey '^s' sudo_toggle  # Ctrl+S to toggle sudo

# Vi mode cursor shapes
function zle-keymap-select {
    case $KEYMAP in
        vicmd|visual) echo -ne '\e[2 q';;  # block cursor
        viins|main)   echo -ne '\e[6 q';;  # beam cursor
        replace)      echo -ne '\e[4 q';;  # underscore cursor
    esac
}
zle -N zle-keymap-select
echo -ne '\e[6 q'  # beam cursor on startup (insert mode)


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

alias c='qalc'
alias makepkg-atomic='~/Scripts/makepkg-atomic.sh'
alias dl='~/.config/niri/scripts/download.sh'
alias sudo='sudo ' # allows aliases with sudo
alias tm='trash'
alias ..='cd ..'
alias ...='cd ../..'
alias .3='cd ../../..'
alias .4='cd ../../../..'
alias .5='cd ../../../../..'
alias mkdir='mkdir -pv'
touch() { mkdir -p "$(dirname "$1")" && command touch "$1" ; }
alias l='eza -lh --icons=auto'
alias ls='eza -1 --icons=auto'
alias ll='eza -lha --icons=auto --sort=name --group-directories-first'
alias ld='eza -lhD --icons=auto'
alias lt='eza --icons=auto --tree'
alias cat='bat'
alias bat='bat --paging never --style=numbers,header-filename'
alias v="nvim"
alias less="$MANPAGER"
yayclean() {
    local orphans
    orphans=$(yay -Qdtq 2>/dev/null)
    if [[ -n "$orphans" ]]; then
        sudo yay -Rsn $orphans
    else
        echo "No orphan packages found"
    fi
}
alias brb="clear && figlet BRB | lolcat"
alias sc='systemctl'
alias scu='systemctl --user'
alias grep='grep --color=auto'
alias fgrep='grep -F --color=auto'
alias egrep='grep -E --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'

alias -g H='--help'
alias -g L="| $MANPAGER"
alias -g G='| grep'
alias -g W='| wc'
alias -g J='| jq'
alias -g C='| tee /dev/tty | perl -pe "chomp if eof" | wl-copy'
alias -g CC='| tee /dev/tty | (echo "❯ $ZSH_COMMAND"; perl -pe "chomp if eof") | wl-copy'
preexec() { echo -ne '\e[6 q'; ZSH_COMMAND=$1 }  # beam cursor before command + save command for CC alias
alias -g null='/dev/null'
alias -g 2null='&>null'
alias -g 2bg='&>null & disown'

# Last command (!!) expansion
function _expand_last_command() {
    LBUFFER="${LBUFFER}${history[$((HISTCMD-1))]}"
}
zle -N _expand_last_command
bindkey '!!' _expand_last_command

# Load environment files (runs on every interactive shell start)
function load_environment_files() {
    set -a
    [[ -f ~/.api_keys.env ]] && source ~/.api_keys.env
    [[ -f .env ]] && source ./.env
    set +a
}
load_environment_files

function stow_dotfiles {
    local cwd=$(pwd)
    cd ~/.dotfiles/ && stow -D . && stow . --adopt && cd "$cwd"
}

# Plugins (install: paru -S zsh-syntax-highlighting zsh-autosuggestions)
[[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
# Autosuggestions honor the same blocklist as history
ZSH_AUTOSUGGEST_HISTORY_IGNORE="$HISTORY_IGNORE"

# fzf integration - load last to ensure binding is not overwritten
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

# Load theme last
source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme
[[ -f $ZDOTDIR/.p10k.zsh ]] && source $ZDOTDIR/.p10k.zsh

# Lazy init tools (only when needed)
if (( $+commands[pyenv] )) && [[ -f .python-version ]]; then
    eval "$(pyenv init - zsh 2>/dev/null)" 2>/dev/null || true
fi
[[ -f .venv/bin/activate ]] && source .venv/bin/activate 2>/dev/null

# Fast tools
if (( $+commands[zoxide] )); then
    eval "$(zoxide init zsh 2>/dev/null)" 2>/dev/null || true
fi

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

