# vim: ft=zsh
# Environment and PATH

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
