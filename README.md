# trunkyard

Centralized git worktrees and workspace-wide git operations, as one small CLI.

- **`trunkyard status [path]`** — git status across every repo under a parent
  directory: branch, dirt, ahead/behind, and worktree checkouts, in one table.
- **`trunkyard pull [path]`** — pull the repos `status` discovers, main
  checkouts before their worktrees, with per-repo locking.
- **`trunkyard new <branch>`** — create a centralized worktree at
  `~/worktrees/<project>/<branch>` (`^` in the path stands in for `/` in
  branch names), reusing the branch or remote tracking ref when one exists.

> Status: in development, pre-cutover. The canonical copies still live in the
> author's dotfiles; this repo becomes canonical at cutover.

## Install

Via [mise](https://mise.jdx.dev)'s github backend (a release ships a
`trunkyard.tar.gz` asset):

```toml
[tools]
"github:aurokin/trunkyard" = { version = "latest", asset_pattern = "trunkyard.tar.gz", bin = "trunkyard/bin/trunkyard" }
```

Or clone and put `bin/trunkyard` on PATH — the CLI self-locates its internals.

Suggested aliases (the ones the author types):

```zsh
alias gwss="trunkyard status"
alias gwp="trunkyard pull"
alias gwt="trunkyard new"
```

## Requirements

bash >= 3.2 (macOS system bash works) and git. No other dependencies.

## Layout

- `bin/trunkyard` — dispatcher.
- `libexec/git-workspace.sh` — status/pull engine.
- `libexec/git-new-worktree.sh` — worktree creation.
- `lib/git-worktree-paths.sh` — shared path resolution (worktree roots,
  `^`-encoding, project inference).

## Docs and tests

Full behavior reference (path conventions, worktree lifecycle, edge cases):
[docs/worktrees.md](docs/worktrees.md). Integration suite: `tests/integration.sh`
(52 tests against real temporary repos).
