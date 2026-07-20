# Agent Instructions

## Status
- Pre-cutover: canonical copies of `libexec/*` and `lib/*` live in `~/.dotfiles/zsh/.zshrc.d/scripts/` and are in daily use there.
- Behavior parity with the dotfiles copies is the contract; behavioral changes must be deliberate and noted in commit messages.

## Layout
- `bin/trunkyard` — thin dispatcher (`status`/`pull` → `libexec/git-workspace.sh`, `new` → `libexec/git-new-worktree.sh`).
- `libexec/` — the engines; they self-locate and source `lib/git-worktree-paths.sh` via `../lib/`.
- `lib/git-worktree-paths.sh` — shared path/branch resolution; sourced, never executed.
- `scripts/release.sh` — tags, pushes, and uploads the `trunkyard.tar.gz` release asset mise installs from.

## Commands
| Task | Command |
|------|---------|
| Integration tests (52, real temp repos) | `tests/integration.sh` |
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
