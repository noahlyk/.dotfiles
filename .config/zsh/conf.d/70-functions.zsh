# vim: ft=zsh
# Functions and environment loading

# Load environment files (runs on every interactive shell start)
function load_environment_files() {
    set -a
    [[ -f ~/.api_keys.env ]] && source ~/.api_keys.env
    [[ -f .env ]] && source ./.env
    set +a
}
load_environment_files

function stow_dotfiles {
    local cwd=$(pwd)
    cd ~/.dotfiles/ && stow -D . && stow . --adopt && cd "$cwd"
}

# bd: cd up to a named parent directory
[[ -f $ZDOTDIR/lib/bd.zsh ]] && source $ZDOTDIR/lib/bd.zsh

# mkcd — make a directory (and parents) then enter it
mkcd() {
    mkdir -p "$1" && cd "$1"
}

# extract — unpack almost any archive with one command
extract() {
    if [[ -z "$1" ]]; then
        echo "Usage: extract <archive>" >&2
        return 1
    fi
    if [[ ! -f "$1" ]]; then
        echo "extract: '$1' is not a file" >&2
        return 1
    fi
    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1" ;;
        *.tar.gz|*.tgz)   tar xzf "$1" ;;
        *.tar.xz|*.txz)   tar xJf "$1" ;;
        *.tar.zst)        tar --zstd -xf "$1" ;;
        *.tar)            tar xf "$1" ;;
        *.bz2)            bunzip2 "$1" ;;
        *.gz)             gunzip "$1" ;;
        *.xz)             unxz "$1" ;;
        *.zst)            unzstd "$1" ;;
        *.zip)            unzip "$1" ;;
        *.rar)            unrar x "$1" ;;
        *.7z)             7z x "$1" ;;
        *.Z)              uncompress "$1" ;;
        *) echo "extract: don't know how to extract '$1'" >&2; return 1 ;;
    esac
}
