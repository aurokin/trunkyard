# Git Worktrees

This document describes the git worktree workflow for this repo:

- the current custom commands and layout
- the supporting workspace commands
- the `worktrunk` trial and possible long-term migration path

## Current Model

### Commands

- `gwt <branch>` is the only custom worktree creation command.
- `gwss <path>` shows workspace status.
- `gwp <path>` pulls repos in a workspace.
- `gsw` and the old repo-local container flow are removed.

### Centralized layout

Worktrees live under:

- `~/worktrees/<project>/<branch>`

Branch paths use the repo’s existing slug rule:

- `/` becomes `^`

Example:

- `~/code/devlane` + `feature/login`
- `~/worktrees/devlane/feature^login`

### `gwt` behavior

#### Branch resolution

- If the branch exists locally, use it.
- If the branch does not exist locally:
  - check remotes in this order:
    - the remote configured for the current branch
    - `origin`
    - all other remotes
  - if exactly one remote has the branch, use it and configure upstream tracking
  - if more than one remote has it, fail and require the user to create the local branch manually first
  - if no remote has it, create it from the current branch in the current checkout

#### Where it can run

- `gwt` can run from any checkout of the repo, including linked worktrees.
- detached HEAD is rejected
- dirty working trees are allowed

#### Path rules

- destination is always `~/worktrees/<project>/<branch-slug>`
- `~/worktrees` and `~/worktrees/<project>` are created automatically
- project name is derived from repo context, not just the current directory basename
- path checks use canonical path resolution

#### Rejections and collisions

- fail if the target branch is already checked out in the current checkout
- fail if the target branch is already checked out elsewhere
- fail if Git has a stale worktree registration and suggest `git worktree prune`
- fail if the destination path already exists
- fail if `~/worktrees/<project>` is itself a git repo
- detect `/ -> ^` slug collisions and fail clearly

#### Output

- on success, print only the final `~/worktrees/...` path
- cleanup guidance uses absolute paths for copy-paste safety

### Shared path helper

Path logic is centralized in:

- [`zsh/.zshrc.d/scripts/git-worktree-paths.sh`](/Users/auro/.dotfiles/zsh/.zshrc.d/scripts/git-worktree-paths.sh)

It owns:

- canonical repo root resolution
- project-name derivation
- branch slugging
- centralized target path generation
- `~/worktrees` path classification

## Workspace Commands

### General scanning

- outside `~/worktrees`, `gwss` and `gwp` scan only one level deep
- old `.git-worktree-container` behavior is fully removed

### Special handling for `~/worktrees`

When the resolved base path is exactly `$HOME/worktrees`:

- scan direct repos at `~/worktrees/<project>`
- scan nested repos at `~/worktrees/<project>/<branch>`
- do not scan deeper than two levels

### `gwss ~/worktrees`

Prints two separate tables:

- `Direct Repos`
- `Nested Worktrees`

Rules:

- omit empty sections
- keep one combined summary line
- sectioning is presentation only

### `gwp ~/worktrees`

- follows the same ordering as `gwss ~/worktrees`
- processes direct repos first, then nested worktrees
- path-sorted within each category

## Tests

Integration coverage lives in:

- [`tests/git-worktree-integration.sh`](/Users/auro/.dotfiles/tests/git-worktree-integration.sh)

The suite covers:

- existing local branches
- remote-only branches
- new branches from the current branch
- duplicate branch handling
- stale registrations
- cleanup guidance
- slash remotes
- local upstreams
- separate-git-dir repos
- `~/worktrees` scanning and ordering
- bare repos
- Bash 3 compatibility

## Worktrunk Trial

### Current decision

- keep the current custom `gwt` for now
- keep `gwss` and `gwp`
- trial `worktrunk` in parallel
- if the trial goes well, replace most of the custom `gwt` implementation with a thin wrapper over `wt switch`

### Why evaluate it

`worktrunk` already provides:

- configurable worktree path templates
- remote-only branch switching
- existing worktree switching
- shell integration for directory changes
- hooks
- list/remove/merge/relocate/prune workflows

Useful references:

- https://worktrunk.dev/
- https://worktrunk.dev/config/
- https://worktrunk.dev/switch/
- https://worktrunk.dev/list/
- https://worktrunk.dev/step/
- https://github.com/max-sixty/worktrunk

### `gwt` vs `worktrunk`

#### What maps cleanly

- centralized path
  - current: `~/worktrees/<project>/<branch-slug>`
  - `worktrunk`: `~/worktrees/{{ repo }}/{{ branch | sanitize }}`
- existing local branch
  - current: `gwt <branch>`
  - `worktrunk`: `wt switch <branch>`
- remote-only branch
  - current: `gwt <branch>`
  - `worktrunk`: `wt switch <branch>`

#### What does not match exactly

- new branch creation
  - current: `gwt <branch>` auto-creates from the current branch
  - `worktrunk`: `wt switch --create --base=@ <branch>`
- duplicate branch behavior
  - current: hard-error if already checked out elsewhere
  - `worktrunk`: switches to the existing worktree
- branch slug format
  - current: `feature/login -> feature^login`
  - `worktrunk`: `feature/login -> feature-login`
- workspace scanning
  - current: `gwss` / `gwp` scan arbitrary parent directories
  - `worktrunk`: repo-scoped `wt list`

### Repo-managed `worktrunk` setup

This repo now carries the trial setup:

- install via Homebrew, not `mise`
- stow package:
  - [`worktrunk/.config/worktrunk/config.toml`](/Users/auro/.dotfiles/worktrunk/.config/worktrunk/config.toml)
- zsh integration owned by this repo:
  - [`zsh/.zshrc.d/worktrunk.zsh`](/Users/auro/.dotfiles/zsh/.zshrc.d/worktrunk.zsh)

Current user config:

```toml
worktree-path = "~/worktrees/{{ repo }}/{{ branch | sanitize }}"
skip-shell-integration-prompt = true
```

The intention is:

- let Homebrew install `wt`
- let the stowed config own `~/.config/worktrunk/config.toml`
- keep shell integration in repo-managed zsh config using `wt config shell init`
- avoid letting `wt config shell install` modify `~/.zshrc` directly

Recommended trial aliases:

- `wts='wt switch'`
- `wtc='wt switch --create --base=@'`
- `wtr='wt remove'`
- `wtct`, `wtrt`, and the `prefix+t`/`prefix+y` pickers below are provided by the [twigsmux](https://github.com/aurokin/twigsmux) TPM plugin, not this repo.
- `wtrt <worktree>` removes the worktree from the current repo context with `wt remove --force-delete`, then kills exactly one matching non-current tmux session when found
- `wtrt --cwd <repo-path> <worktree>` removes the worktree from an explicit repo context, which lets tmux picker removals work even when launched from another repo's session
- `wtrt --session <tmux-session> <worktree>` scopes tmux cleanup to that exact session instead of suffix-matching every session
- `prefix+y` opens the tmux session picker from the current directory; when it creates a new session it runs `wtct`, creates/switches a `worktrunk` worktree for the requested branch, and scaffolds the standard tmux windows.
  If the new session keeps the prefilled `<current-session>-` prefix, that prefix is stripped from the branch name; otherwise the session name is used as the branch name directly.
- `prefix+y` records the resolved branch on the new tmux session as `@twigsmux_worktree_branch` and the repo context as `@twigsmux_worktree_cwd`.
- In the `prefix+t` / `prefix+y` picker, `ctrl-r` removes the selected worktree via `wtrt`; sessions created by `prefix+y` use the recorded branch and repo context, sessions already sitting inside `~/worktrees/<project>/<worktree>` use that worktree name and infer the main checkout as repo context, legacy ticket-style sessions use the old `project-ticket-123` to `ticket-123` fallback, and other project-prefixed sessions such as `diffwarden-streaming` strip the owning project prefix. Empty targets and the current session's own worktree are ignored. If a selected session's pane path, session path, or session name point at conflicting worktrees, removal is refused instead of guessing.

Quick translation:

- existing local branch
  - current: `gwt feature/foo`
  - `worktrunk`: `wts feature/foo`
- remote-only branch
  - current: `gwt release`
  - `worktrunk`: `wts release`
- new branch from the current branch
  - current: `gwt feature/foo`
  - `worktrunk`: `wtc feature/foo`
- remove a worktree
  - `worktrunk`: `wtr feature/foo`
- remove a worktree and matching tmux session
  - `worktrunk`: `wtrt feature/foo` (uses `--force-delete`)
- branch already checked out elsewhere
  - current: hard-error
  - `worktrunk`: switches to the existing worktree
- branch path format
  - current: `feature^foo`
  - `worktrunk`: `feature-foo`

### Trial workflow

Use `worktrunk` on a small number of repos first.

Equivalent trial commands:

- existing local branch
  - `gwt feature/foo`
  - `wts feature/foo`
- remote-only branch
  - `gwt release`
  - `wts release`
- new branch from current branch
  - `gwt feature/foo`
  - `wtc feature/foo`

Things to evaluate explicitly:

- whether `feature-login` is acceptable instead of `feature^login`
- whether "switch to existing worktree" feels better than the current hard-error rule
- whether shell integration is reliable enough to trust daily
- whether `wt list` adds enough value even though it does not replace `gwss`
- whether hooks / relocate / prune reduce enough maintenance to justify the shift

### Long-term migration shape

Do not replace `gwt` with raw `wt switch` directly.

If the trial is positive, the right shape is:

- keep `gwss` / `gwp`
- keep current `gwt` during the trial
- later replace `gwt` with a small wrapper over `wt switch`

Target wrapper behavior:

- if branch exists locally: `wt switch <branch>`
- else if branch exists on exactly one remote: `wt switch <branch>`
- else: `wt switch --create --base=@ <branch>`

Important:

- keep the wrapper small
- do not port all current path and recovery logic into it
- let `worktrunk` own path creation and switching behavior

### Exit criteria

Move from trial to wrapper only if all of these are true:

- `worktrunk` feels stable in daily use
- path format differences are acceptable
- duplicate-branch behavior is acceptable or easy to wrap
- new-branch-from-current is easy to express with a tiny wrapper
- it clearly reduces maintenance burden versus the current custom script

Stay on the current custom `gwt` if any of these remain unacceptable:

- branch path format must stay `^`-based
- hard-error semantics are required instead of switching
- `wt switch --create --base=@` feels too different from `gwt <branch>`
- `worktrunk` shell integration is unreliable in practice
