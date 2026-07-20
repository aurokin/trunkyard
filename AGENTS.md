# Agent Instructions

## Status
- This repo is canonical; it shipped from a dotfiles extraction (see `docs/worktrees.md` for the behavior contract the extraction preserved).

## Layout
- `bin/trunkyard` — thin dispatcher (`status`/`pull` → `libexec/git-workspace.sh`, `new` → `libexec/git-new-worktree.sh`).
- `libexec/` — the engines; they self-locate and source `lib/git-worktree-paths.sh` via `../lib/`.
- `lib/git-worktree-paths.sh` — shared path/branch resolution; sourced, never executed.
- `scripts/release.sh` — tags, pushes, and uploads the `trunkyard.tar.gz` release asset mise installs from.

## Commands
| Task | Command |
|------|---------|
| Integration tests (real temp repos) | `tests/integration.sh` |
| Dispatcher tests (routing, symlink regression) | `tests/dispatcher.sh` |
| Syntax check | `bash -n bin/trunkyard libexec/*.sh lib/*.sh` |
| Release | `scripts/release.sh vX.Y.Z` |

## Key Conventions
- Everything is bash >= 3.2 compatible (macOS system bash); no zsh, no external deps beyond git.
- Tests create real repos under `mktemp -d` only — never operate on real checkouts or `~/worktrees`.
- Worktree paths encode `/` in branch names as `^` (see `lib/git-worktree-paths.sh`); do not change the encoding — existing worktrees on the fleet depend on it.
- Run `tests/integration.sh` after any change to `libexec/` or `lib/`.

## External References
| Need | File |
|------|------|
| User docs, install, aliases | `README.md` |
| Behavior reference (paths, lifecycle, edge cases) | `docs/worktrees.md` |
