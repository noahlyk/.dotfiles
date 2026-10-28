# Dotfiles repo: git workflow

This repo (`~/.dotfiles`) is the user's live config. Edits here take effect on their system, so the repo must always mirror reality. These rules override the default "branch / ask before committing" behavior.

## 1. Commit directly on `main`
- Make commits straight on `main`. No permission needed, don't ask first.
- Don't use worktrees for edits here; work in `~/.dotfiles` itself so changes are live immediately.

## 2. No branches unless explicitly asked
- Never create branches, worktrees, or PRs unless the user says so.
- Assume the user wants plain commits on `main`, checked out and live right away.
- Push `main` to `origin` after committing, no permission needed. Don't hold commits locally: every commit you make goes to `origin` right away. `git push --force-with-lease` is also allowed without asking (needed after fixup/squash rewrites). Never plain `--force`.

## 3. Two commits per change: cleanup first, then the change
Before committing your actual edit, make one extra cleanup commit that tidies the working tree:
- Add `.gitignore` entries for things that shouldn't be tracked (caches, logs, locks, window state, generated files, machine-local state).
- Start tracking (or stage) real edits to config that belongs in the repo but is currently untracked or modified.

Then make your own commit with just the change you made. Order: **cleanup commit → your commit**. If the tree is already clean, skip the cleanup commit.

Stage explicit paths, not `git add -A`. git-crypt-encrypted files (`.ssh/**`, `.tableplus/**`, `.projects`, `.config/git/identity*`, `.config/git/gitleaks.toml`) show up as spurious modifications from re-encryption noise: never stage those unless they were genuinely edited.

## 4. Revise history instead of stacking commits
Keep `main` clean: one tidy commit per feature/fix, not a trail of corrections.
- **Fixup, don't pile on.** If you revise something you committed earlier in this session, make a `git commit --fixup=<sha>` and fold it in with `git rebase --autosquash` rather than adding a new "fix the fix" commit.
- **Drop, don't revert.** If a commit from this session turned out wrong or unwanted, drop it from history (rebase and drop, or `git reset` back past it) instead of adding a `git revert` commit.
- **Squash related commits.** Collapse several commits for one feature into one before you finish. Squash noisy cleanup/tweak commits into the commit they belong to.
- Only rewrite commits you made in this session. Never rewrite the user's own older commits. Commits you already pushed may be rewritten, then pushed with `--force-with-lease`.
- Rebases are non-interactive here (no `-i`): use `GIT_SEQUENCE_EDITOR=true git rebase --autosquash <base>` for fixups, and `git reset --soft`/`git rebase --onto` for squashes and drops. Rewriting history needs a clean working tree, so use `git stash push -u -m "<unique-tag>"` and apply it back by SHA if you must (the stash stack is shared; never bare `git stash pop`).

Goal: the repo stays properly maintained through every edit and the dotfiles are always up to date on `main`.
