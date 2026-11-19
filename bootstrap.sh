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

# --- CachyOS repo (x86-64-v3) ---
# packages.txt includes linux-cachyos, scx-*, and packages that moved off the AUR
# list because the CachyOS repos ship them, so the repo must exist before the
# explicit-package install. Mirrors the official cachyos-repo.sh for a v3 (not
# v4/znver4) CPU, e.g. the Ryzen 9 5900X. Idempotent.
if /lib/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v3 (supported, searched)' \
   && ! grep -q '^\[cachyos-v3\]' /etc/pacman.conf; then
    echo "Adding CachyOS v3 repos..."
    sudo pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
    sudo pacman-key --lsign-key F3B607488DB35A47
    cachy_mirror="https://mirror.cachyos.org/repo/x86_64/cachyos"
    sudo pacman -U --noconfirm \
        "$cachy_mirror/cachyos-keyring-20240331-1-any.pkg.tar.zst" \
        "$cachy_mirror/cachyos-mirrorlist-27-1-any.pkg.tar.zst" \
        "$cachy_mirror/cachyos-v3-mirrorlist-27-1-any.pkg.tar.zst" \
        "$cachy_mirror/cachyos-v4-mirrorlist-27-1-any.pkg.tar.zst" \
        "$cachy_mirror/pacman-7.1.0.r9.g54d9411-6-x86_64.pkg.tar.zst"
    # Insert the four repo sections above [core] (the order the official script uses).
    sudo cp /etc/pacman.conf /etc/pacman.conf.pre-cachyos
    sudo awk '
        /^\[core\]$/ && !done {
            print "[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n"
            print "[cachyos-core-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n"
            print "[cachyos-extra-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n"
            print "[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n"
            done = 1
        }
        { print }' /etc/pacman.conf.pre-cachyos | sudo tee /etc/pacman.conf >/dev/null
    sudo pacman -Syu --noconfirm
fi

# --- scx scheduler (sched_ext): scx_lavd in Gaming mode, run by scx_loader ---
# The scx_loader.service unit itself is enabled via .config/systemd/system/enabled.list.
sudo mkdir -p /etc/scx_loader
printf 'default_sched = "scx_lavd"\ndefault_mode = "Gaming"\n' | sudo tee /etc/scx_loader/config.toml >/dev/null

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

# --- Flatpaks ---
if [[ -f flatpaks.txt ]]; then
    echo "Installing flatpaks..."
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    while IFS= read -r ref; do
        [[ -z "$ref" || "$ref" == \#* ]] && continue
        if ! flatpak info "$ref" >/dev/null 2>&1; then
            flatpak install -y flathub "$ref"
        fi
    done < flatpaks.txt
fi

echo "Restowing directories..."
stow -R .

# Command shims that stow can't own (a tracked ~/.local/bin could make stow fold
# the whole dir into the repo and swallow uv/pip installs). ~/Scripts is itself
# a stow-made symlink to Scripts/.
mkdir -p "$HOME/.local/bin"
ln -sfn "$HOME/Scripts/games/gamelaunch" "$HOME/.local/bin/gamelaunch"
# Steam's launch options run through sh with a PATH that can lack ~/.local/bin
# (Steam started by autostart/session, not a login shell: "gamelaunch: command not
# found" and the game exits instantly), so also expose it on the system PATH.
sudo ln -sfn "$HOME/Scripts/games/gamelaunch" /usr/local/bin/gamelaunch

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
