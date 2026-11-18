# Scripts

Single home for every personal script. `~/Scripts` is a symlink to this dir.
Tools that insist on their own config dirs get a symlink back here instead of a copy:

| Dir | Contents | Reached via |
|---|---|---|
| `niri/` | compositor helpers (workspace/column/focus/OCR/download) | `~/.config/niri/scripts` -> `../../Scripts/niri` |
| `tmux/` | status-bar segments, session/Claude pickers, nav | `~/.config/tmux/scripts` -> `../../Scripts/tmux` |
| `games/` | `gamelaunch`, Sober launch + FPS patch | `~/.local/bin/gamelaunch` |
| `audio/` | mic modes, TTS, mp4 -> mp3 | DMS plugin settings |
| `video/` | trim/split, OBS, screenshots | |
| `system/` | packaging, ssh, fastfetch, wallpaper, misc | zsh aliases |
| `git/` | `git-linearize` | `git linearize` alias |
| `notes/`, `research_notes/` | write-ups, not executables | |

Adding a script: put it in the matching subdir, `chmod +x`, reference it by its
`~/Scripts/<dir>/<name>` path (or via the symlinked config dir for niri/tmux).
