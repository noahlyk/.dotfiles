# Shared fzf look for tmux popups (Alt+s sessions, Alt+f projects). Source it, then use "${FZF_STYLE[@]}".

theme_hex() { tmux show -gv "@thm_$1" 2>/dev/null; }

ansi_fg() {
  local hex=${1#\#}
  printf '\033[38;2;%d;%d;%dm' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

build_fzf_style() {
  local text surface_0 surface_1 overlay_1 mauve
  text=$(theme_hex fg); surface_0=$(theme_hex surface_0); surface_1=$(theme_hex surface_1)
  overlay_1=$(theme_hex overlay_1); mauve=$(theme_hex mauve)
  FZF_STYLE=(
    --layout=reverse --height=100% --margin=0 --border=none
    --prompt='  ' --pointer='▌' --marker='' --info=inline-right --no-scrollbar
    --preview-window='right,55%,border-left'
    --color="bg:-1,bg+:${surface_0},fg:${text},fg+:${text},hl:${mauve},hl+:${mauve}"
    --color="pointer:${mauve},prompt:${mauve},info:${overlay_1},header:${overlay_1}"
    --color="border:${surface_1},separator:${surface_1},preview-border:${surface_1},gutter:-1"
  )
}
