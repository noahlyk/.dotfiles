#!/usr/bin/env bash
set -euo pipefail

# tracked-packages-exclude: yay-bin
# (installed here via makepkg, not pacman/yay -S, so save-state.sh must not
#  re-add it to packages.txt/packages-aur.txt as if it were untracked)

if ! pacman -Qq yay >/dev/null 2>&1; then
    (
        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' EXIT
        cd "$tmpdir"
        sudo pacman -S --needed --noconfirm git base-devel
        git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin
        makepkg -si
    )
fi

