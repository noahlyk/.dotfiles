#!/usr/bin/env bash
set -euo pipefail

chmod 700 ~/.ssh

for pub in ~/.ssh/*.pub; do
    [[ -e "$pub" ]] || continue
    chmod 644 "$pub"
    priv="${pub%.pub}"
    if [[ -f "$priv" ]]; then
        chmod 600 "$priv"
        ssh-add "$priv" > /dev/null 2>&1 || true
    fi
done

[[ -f ~/.ssh/config ]] && chmod 600 ~/.ssh/config
[[ -f ~/.ssh/authorized_keys ]] && chmod 600 ~/.ssh/authorized_keys
[[ -f ~/.ssh/known_hosts ]] && chmod 644 ~/.ssh/known_hosts
