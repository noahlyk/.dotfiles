#!/usr/bin/env bash
set -euo pipefail

echo "Saving current system state into the repo..."

# --- Git-style minimal diff function ---
show_diff() {
    local old="$1"
    local new="$2"
    diff --old-line-format=$'\e[31m- %L\e[0m' \
         --new-line-format=$'\e[32m+ %L\e[0m' \
         --unchanged-line-format='' <(echo "$old") <(echo "$new") || true
}

# --- Packages tracked-packages.sh installs itself, to exclude from state ---
custom_words=$(grep -oP '^# tracked-packages-exclude:\s*\K.*' packages-custom.sh 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u || true)

# --- Explicit AUR packages ---
echo "Recording explicit AUR packages..."
old_aur=""
[[ -f packages-aur.txt ]] && old_aur=$(<packages-aur.txt)

yay -Qqme | grep -Fxv -f <(echo "$custom_words") | sort > packages-aur.txt
new_aur=$(<packages-aur.txt)
show_diff "$old_aur" "$new_aur"

# --- Explicit pacman packages ---
echo "Recording explicit pacman packages..."
old_pkgs=""
[[ -f packages.txt ]] && old_pkgs=$(<packages.txt)

pacman -Qqe | grep -Fxv -f <(echo "$custom_words") | sort | comm -23 - packages-aur.txt > packages.txt
new_pkgs=$(<packages.txt)
show_diff "$old_pkgs" "$new_pkgs"

# --- Enabled systemd system units ---
echo "Recording enabled systemd system units..."
mkdir -p .config/systemd/system
old_system=""
[[ -f .config/systemd/system/enabled.list ]] && old_system=$(<.config/systemd/system/enabled.list)

systemctl list-unit-files --state=enabled --no-legend --no-pager \
  | awk '{print $1}' | sort > .config/systemd/system/enabled.list

new_system=$(<.config/systemd/system/enabled.list)
show_diff "$old_system" "$new_system"

# --- Enabled systemd user units ---
echo "Recording enabled systemd user units..."
mkdir -p .config/systemd/user
old_user=""
[[ -f .config/systemd/user/enabled.list ]] && old_user=$(<.config/systemd/user/enabled.list)

systemctl --user list-unit-files --state=enabled --no-legend --no-pager \
  | awk '{print $1}' | sort > .config/systemd/user/enabled.list

new_user=$(<.config/systemd/user/enabled.list)
show_diff "$old_user" "$new_user"

echo "Local state saved! Commit your changes to persist."
