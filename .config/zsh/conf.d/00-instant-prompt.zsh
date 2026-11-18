# vim: ft=zsh
# p10k instant prompt: must stay the first thing that runs (nothing above may print or read input)

# Disable gitstatus (must be before instant prompt)
typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true

# Consolidate p10k cache into subdirectory
typeset -g POWERLEVEL9K_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/p10k"

# Enable instant prompt (must be near top)
if [[ -r "$POWERLEVEL9K_CACHE_DIR/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "$POWERLEVEL9K_CACHE_DIR/p10k-instant-prompt-${(%):-%n}.zsh"
fi
