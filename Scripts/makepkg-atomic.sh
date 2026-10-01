#!/usr/bin/env bash
set -euo pipefail

# Atomic makepkg wrapper: copies git-tracked files to a temp dir,
# runs makepkg there, and always cleans up on exit.

# Must be run from within a git repo
if ! git rev-parse --show-toplevel &>/dev/null; then
    echo "error: not inside a git repository" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMPDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Copy all git-tracked + untracked-but-not-ignored files into the temp dir
# git ls-files -co --exclude-standard: cached (tracked) + other (untracked, non-ignored)
git -C "$REPO_ROOT" ls-files -co --exclude-standard | while IFS= read -r file; do
    src="$REPO_ROOT/$file"

    # A nested git repo boundary (e.g. a worktree under .claude/worktrees/,
    # or a submodule) is reported as a single directory entry rather than
    # being recursed into. It isn't part of this package's source, so skip
    # it instead of copying its contents (which is also what a bare `cp`
    # would otherwise fail on with "cp: -r not specified").
    if [ -d "$src" ]; then
        continue
    fi

    dest="$TMPDIR/$file"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
done

cd "$TMPDIR"
makepkg "$@"
