# Fib's configs

## Guide
- Get ArchLinux 🤷 or run the equivalent commands
- run these commands:
```
sudo pacman -S stow git-crypt gnupg
git clone https://github.com/noahlyk/.dotfiles ~/.dotfiles
gpg --decrypt gpg_key.asc.gpg > gpg_key.asc
gpg --import gpg_key.asc
git-crypt unlock
pushd ~/.dotfiles; stow -R .; popd
```

This is the command I used to save and encrypt the gpg_key, just for reference:
```
gpg --export-secret-keys > gpg_key.asc
gpg --symmetric --cipher-algo AES256 gpg_key.asc
```
