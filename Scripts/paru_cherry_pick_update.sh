#!/bin/bash

if ! command -v paru &>/dev/null; then
    echo "Error: paru is not installed" >&2
    exit 1
fi

# Fetch list of updatable packages
packages=$(paru -Qu | awk '{print $1}')

# Check if there are any packages to update
if [ -z "$packages" ]; then
    echo "All packages are up-to-date."
    exit 0
fi

# Array to hold packages selected for update
selected_packages=()

# Iterate over each package
echo "Select packages to update:"
for package in $packages; do
    echo -n "Update $package? [y/N]: "
    read -r choice

    # If the user chooses 'y' or 'Y', add the package to the update list
    if [[ $choice =~ ^[Yy]$ ]]; then
        selected_packages+=("$package")
    fi
done

# Check if any packages were selected for update
if [ ${#selected_packages[@]} -eq 0 ]; then
    echo "No packages selected for update."
    exit 0
fi

# Update selected packages
for package in "${selected_packages[@]}"; do
    paru -S --noconfirm "$package"
done

echo "Update process completed."
