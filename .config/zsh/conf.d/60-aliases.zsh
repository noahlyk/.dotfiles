# vim: ft=zsh
# Aliases, global aliases, small helpers

alias c='qalc'
alias makepkg-atomic='~/Scripts/system/makepkg-atomic.sh'
alias dl='~/Scripts/niri/download.sh'
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
