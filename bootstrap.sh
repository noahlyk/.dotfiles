#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

echo "Bootstrapping your Arch setup..."

sudo -v
{ while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done; } 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# --- git-crypt guard ---
# .ssh/**, .tableplus/**, .projects, .config/git/identity*, .config/git/gitleaks.toml
# are git-crypt encrypted. A fresh clone checks them out as ciphertext; stow would
# then happily symlink that ciphertext into $HOME (e.g. ~/.ssh/id_ed25519) with no
# error. Refuse to stow until they're confirmed unlocked. See README.md for the
# manual unlock steps (gpg --decrypt/--import, git-crypt unlock).
if [[ -f .config/git/gitleaks.toml ]] && [[ "$(file --brief --mime-type .config/git/gitleaks.toml)" != text/* ]]; then
    echo "git-crypt-encrypted files are still locked (e.g. .config/git/gitleaks.toml is ciphertext)." >&2
    echo "Run the gpg import + 'git-crypt unlock' steps from README.md first, then re-run bootstrap.sh." >&2
    exit 1
fi

# --- diff helper ---
show_diff() {
    local old="$1"
    local new="$2"
    diff --old-line-format=$'\e[31m- %L\e[0m' \
         --new-line-format=$'\e[32m+ %L\e[0m' \
         --unchanged-line-format='' \
         <(echo "$old") <(echo "$new") || true
}

echo "Running custom package script..."
./packages-custom.sh

# --- Explicit packages ---
echo "Installing explicit pacman packages..."
mapfile -t missing_pkgs < <(comm -23 <(sort packages.txt) <(pacman -Qq | sort))
if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    sudo pacman -S --needed --noconfirm "${missing_pkgs[@]}"
fi

# --- AUR packages ---
echo "Installing explicit AUR packages..."
while IFS= read -r pkg; do
    if ! yay -Qq "$pkg" >/dev/null 2>&1; then
        yay -S --noconfirm "$pkg"
    fi
done < packages-aur.txt

echo "Restowing directories..."
stow -R .

DOTFILES_SYSTEMD="$(pwd)/.config/systemd"

# --- system units ---
if [[ -f "$DOTFILES_SYSTEMD/system/enabled.list" ]]; then
    echo "Reconciling systemd system units..."

    before=$(systemctl list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort)
    desired=$(sort "$DOTFILES_SYSTEMD/system/enabled.list")

    comm -23 <(echo "$desired") <(echo "$before") | while read -r u; do
        sudo systemctl enable "$u" || true
    done

    comm -13 <(echo "$desired") <(echo "$before") | while read -r u; do
        sudo systemctl disable "$u" || true
    done

    after=$(systemctl list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort)
    show_diff "$before" "$after"

    sudo systemctl daemon-reload
fi

# --- user units ---
if [[ -f "$DOTFILES_SYSTEMD/user/enabled.list" ]]; then
    echo "Reconciling systemd user units..."

    before=$(systemctl --user list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort)
    desired=$(sort "$DOTFILES_SYSTEMD/user/enabled.list")

    comm -23 <(echo "$desired") <(echo "$before") | while read -r u; do
        systemctl --user enable "$u" || true
    done

    comm -13 <(echo "$desired") <(echo "$before") | while read -r u; do
        systemctl --user disable "$u" || true
    done

    after=$(systemctl --user list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort)
    show_diff "$before" "$after"

    systemctl --user daemon-reload
fi

echo "Bootstrap complete!"
echo ""
echo -e "\e[33mRuntime state not fully applied.\e[0m"
echo -e "\e[33mEnabled units now match the repo, but running services may differ.\e[0m"
echo ""
echo -e "\e[36mRecommended (clean + safe):\e[0m"
echo -e "  \e[32msudo reboot\e[0m"
