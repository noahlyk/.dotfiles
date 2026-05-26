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
    $CARGO_HOME/bin
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
bindkey '^s' sudo_toggle  # Ctrl+S to toggle sudo

# Vi mode cursor shapes
function zle-keymap-select {
    case $KEYMAP in
        vicmd|visual) echo -ne '\e[2 q';;  # block cursor
        viins|main)   echo -ne '\e[2 q';;  # block cursor
        replace)      echo -ne '\e[4 q';;  # underscore cursor
    esac
}
zle -N zle-keymap-select
echo -ne '\e[2 q'  # block cursor on startup


HISTFILE="${XDG_STATE_HOME}/zsh/history"
HISTSIZE=50000
SAVEHIST=10000
setopt appendhistory share_history
setopt hist_expire_dups_first  # Expire duplicates first
setopt hist_ignore_dups        # Ignore consecutive duplicates
setopt hist_ignore_all_dups    # Ignore all duplicates in history
setopt hist_ignore_space       # Ignore commands starting with space
setopt hist_find_no_dups       # Don't show duplicates when searching
setopt hist_reduce_blanks      # Remove extra blanks
setopt hist_verify             # Verify history expansion






# Completion system
autoload -Uz compinit
local zcd="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
[[ -f "$zcd" ]] && compinit -C -d "$zcd" || compinit -d "$zcd"

# Keymux completions (generate once with: keymux completion zsh > ~/.zsh/completions/_keymux)

# Completion styling - minimal but functional
zstyle ':completion:*' completer _complete _approximate
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' menu select
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME}/zsh/zcompcache"

# Vi menu navigation
zmodload zsh/complist
bindkey -M menuselect 'h' vi-backward-char
bindkey -M menuselect 'k' vi-up-line-or-history
bindkey -M menuselect 'l' vi-forward-char
bindkey -M menuselect 'j' vi-down-line-or-history

alias makepkg-atomic='~/Scripts/makepkg-atomic.sh'
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
alias fastfetch='~/.config/fastfetch/fastfetch_inline.sh'

alias -g H='--help'
alias -g L="| $MANPAGER"
alias -g G='| grep'
alias -g W='| wc'
alias -g J='| jq'
alias -g C='| tee /dev/tty | perl -pe "chomp if eof" | wl-copy'
alias -g CC='| tee /dev/tty | (echo "❯ $ZSH_COMMAND"; perl -pe "chomp if eof") | wl-copy'
preexec() { echo -ne '\e[2 q'; ZSH_COMMAND=$1 }  # block cursor before command + save command for CC alias
alias -g null='/dev/null'
alias -g 2null='&>null'
alias -g 2bg='&>null & disown'

# Last command (!!) expansion
function _expand_last_command() {
    LBUFFER="${LBUFFER}${history[$((HISTCMD-1))]}"
}
zle -N _expand_last_command
bindkey '!!' _expand_last_command

# Load environment files (lazy)
function load_environment_files() {
    set -a
    [[ -f ~/.api_keys.env ]] && source ~/.api_keys.env
    [[ -f .env ]] && source ./.env
    set +a
}
load_environment_files

function download {
    local highlight=false
    local urls=()
    local other_args=()

    # separate --highlight and URLs
    for arg in "$@"; do
        if [[ "$arg" == "--highlight" ]]; then
            highlight=true
        elif [[ "$arg" =~ ^https?:// ]]; then
            urls+=("$arg")
        else
            other_args+=("$arg")
        fi
    done

    for url in "${urls[@]}"; do
        if [[ "$url" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]; then
            local start=""
            if $highlight; then
                # get first highlight start in seconds
                start=$(yt-dlp "$url" --skip-download --print "sponsorblock_poi_highlight[0].start" 2>/dev/null)
                # only keep numeric start
                if ! [[ "$start" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    start=""
                fi
            fi

            # download video/audio
            yt-dlp "$url" "${other_args[@]}" \
                --merge-output-format mp4 \
                --sponsorblock-mark poi_highlight \
                --no-write-info-json \
                --clean-info-json

            # if highlight and start exists, and output is a video
            if [[ -n "$start" ]]; then
                local vidfile
                vidfile=$(yt-dlp --get-filename "$url" "${other_args[@]}" -o "%(title)s.%(ext)s")
                # only trim if the file exists
                if [[ -f "$vidfile" ]]; then
                    ffmpeg -ss "$start" -i "$vidfile" -c copy "highlight_trimmed_${vidfile}"
                    mv "highlight_trimmed_${vidfile}" "$vidfile"
                fi
            fi

        else
            gallery-dl "$url" -D . --cookies-from-browser firefox "${other_args[@]}"
        fi
    done
}

function stow_dotfiles {
    local cwd=$(pwd)
    cd ~/.dotfiles/ && stow -D . && stow . --adopt && cd "$cwd"
}

# Plugins (install: paru -S zsh-syntax-highlighting zsh-autosuggestions)
[[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# fzf integration - load last to ensure binding is not overwritten
if (( $+commands[fzf] )); then
    __fzf_history__() {
        local selected
        selected=$(fc -rl 1 | awk '!seen[$0]++' | tac | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' | 
            awk 'NR <= 20 && match($0, /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { cmd = $0; if (system("command -v " cmd " >/dev/null 2>&1") != 0) next } { print }' | 
            fzf --tac --no-sort --exact --query="$LBUFFER")
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

# Load theme last
source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme
[[ -f $ZDOTDIR/.p10k.zsh ]] && source $ZDOTDIR/.p10k.zsh

