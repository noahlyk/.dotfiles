# vim: ft=zsh
# Lazy per-directory tooling

if (( $+commands[pyenv] )) && [[ -f .python-version ]]; then
    eval "$(pyenv init - zsh 2>/dev/null)" 2>/dev/null || true
fi
[[ -f .venv/bin/activate ]] && source .venv/bin/activate 2>/dev/null
