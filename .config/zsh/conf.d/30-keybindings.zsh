# vim: ft=zsh
# Vi mode, key bindings, cursor shape

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

