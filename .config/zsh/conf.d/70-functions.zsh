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
