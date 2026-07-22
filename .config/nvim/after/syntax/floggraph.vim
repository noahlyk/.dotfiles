" Extra highlighting layered on flog's own syntax for the git-log graph.
"
" This lives in after/syntax so Vim sources it *after* syntax/floggraph.vim —
" which guarantees flog's flogHash / flogRef groups already exist when we attach to
" them with `containedin`. (Doing this from a FileType autocmd is load-order
" dependent: if the autocmd runs before flog's syntax loads, the containedin binds
" to nothing and silently no-ops — which is exactly what greyed out the hash
" brackets and left origin/* uncolored.)

" Show the hash without its brackets. flog only colors a *bracketed* hash, and that
" match anchors the whole ref-color chain, so we keep the [%h] format and simply
" conceal the [ ] here (flog's ftplugin already sets conceallevel=2).
syntax match flogHashBracket contained containedin=flogHash conceal /[][]/

" Color origin/* red. flog's built-in flogRefRemote matches "remotes/…", which never
" appears in the short decoration ("origin/main"), so it never fires — match origin/
" ourselves. Keyed on origin/ so local branches that contain a slash (e.g.
" nvim/gitlog-fs-event) stay green.
syntax match flogRefRemote contained containedin=flogRef /\v<origin\/[^ ,)]+/
