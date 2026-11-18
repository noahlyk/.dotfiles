#!/usr/bin/env zsh
# Thin loader: all configuration lives in conf.d/, sourced in numeric order.
#   00 instant-prompt  10 env  20 options  30 keybindings  40 history  50 completion
#   60 aliases  70 functions  80 plugins  90 prompt  95 tools
# lib/ holds bigger pieces that conf.d files pull in on demand (fzf history picker).
# Startup profiling: `ZSH_PROFILE=1 zsh -i`.

# Skip non-interactive shells
[[ -o interactive ]] || return

[[ -n $ZSH_PROFILE ]] && zmodload zsh/zprof

for _zrc in "$ZDOTDIR"/conf.d/*.zsh(N); do
    source "$_zrc"
done
unset _zrc

[[ -n $ZSH_PROFILE ]] && zprof
