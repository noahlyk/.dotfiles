#!/usr/bin/env zsh

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:=${HOME}/.config}"
export XDG_STATE_HOME="${XDG_STATE_HOME:=${HOME}/.local/state}"
export XDG_DATA_HOME="${XDG_DATA_HOME:=${HOME}/.local/share}"
export ZDOTDIR="${ZDOTDIR:=${XDG_CONFIG_HOME}/zsh}"

if ! source $ZDOTDIR/.zshenv; then
    echo "FATAL Error: Could not source $ZDOTDIR/.zshenv"
    return 1
fi
