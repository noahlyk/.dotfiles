# vim: ft=zsh
# Plugins

# Plugins (install: paru -S zsh-syntax-highlighting zsh-autosuggestions)
[[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
# Autosuggestions honor the same blocklist as history
ZSH_AUTOSUGGEST_HISTORY_IGNORE="$HISTORY_IGNORE"

# fzf: Ctrl-R history picker (with ctrl-x purge). Loaded last so its bindings win.
[[ -f $ZDOTDIR/lib/fzf-history.zsh ]] && source $ZDOTDIR/lib/fzf-history.zsh
