# vim: ft=zsh
# Plugins. All optional: a missing one is skipped silently.
#   install: paru -S zsh-completions zsh-autosuggestions zsh-syntax-highlighting \
#                    fzf-tab-git zsh-you-should-use pay-respects
# Order matters: fzf-tab right after compinit and before anything that wraps widgets,
# then the widget wrappers, then fzf-history (so its ^R wins), and syntax-highlighting
# last of all (its docs require being the final widget wrapper sourced).

_zplugin() {
    local -a found
    found=( ${~1}(N) )
    [[ -n $found ]] && source $found[1]
}

# fzf-tab: Tab opens fzf over the completion candidates (needs compinit, done in 50-completion)
if _zplugin '/usr/share/zsh/plugins/fzf-tab*/fzf-tab.plugin.zsh'; then
    zstyle ':completion:*:descriptions' format '[%d]'
    zstyle ':completion:*' menu no                                   # fzf-tab replaces the menu
    zstyle ':fzf-tab:*' switch-group '<' '>'                         # < / > flip between groups
    zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --icons=auto --color=always $realpath'
    zstyle ':fzf-tab:complete:(nvim|v|bat|cat):*' fzf-preview 'bat --color=always --style=numbers --line-range=:200 $realpath 2>/dev/null || eza -1 --icons=auto --color=always $realpath'
fi

_zplugin '/usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh'
# Autosuggestions honor the same blocklist as history
ZSH_AUTOSUGGEST_HISTORY_IGNORE="$HISTORY_IGNORE"

# Remind me when an alias already exists for what I typed
YSU_MESSAGE_POSITION=after
_zplugin '/usr/share/zsh/plugins/zsh-you-should-use/you-should-use.plugin.zsh'

# `f` re-runs / fixes the last command (pay-respects, thefuck's successor)
(( $+commands[pay-respects] )) && eval "$(pay-respects zsh --nocnf --alias f)"

# fzf: Ctrl-R history picker (with ctrl-x purge). Loaded after the wrappers so its bindings win.
[[ -f $ZDOTDIR/lib/fzf-history.zsh ]] && source $ZDOTDIR/lib/fzf-history.zsh

_zplugin '/usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh'
unfunction _zplugin
