# trunkyard behavior reference

The commands, layout rules, and edge-case behavior of `trunkyard status`,
`trunkyard pull`, and `trunkyard new` (aliases used throughout: `gwss`,
`gwp`, `gwt`).

## Centralized layout

Worktrees live under:

- `~/worktrees/<project>/<branch>`

Branch paths slug `/` as `^`:

- `~/code/devlane` + `feature/login` → `~/worktrees/devlane/feature^login`

## `trunkyard new` (`gwt`)

### Branch resolution

- If the branch exists locally, use it.
- If the branch does not exist locally:
  - check remotes in this order: the remote configured for the current
    branch, then `origin`, then all other remotes
  - if exactly one remote has the branch, use it and configure upstream
    tracking
  - if more than one remote has it, fail and require the user to create the
    local branch manually first
  - if no remote has it, create it from the current branch in the current
    checkout

### Where it can run

- Any checkout of the repo, including linked worktrees.
- Detached HEAD is rejected; dirty working trees are allowed.

### Path rules

- Destination is always `~/worktrees/<project>/<branch-slug>`.
- `~/worktrees` and `~/worktrees/<project>` are created automatically.
- Project name is derived from repo context, not just the current directory
  basename; path checks use canonical path resolution.

### Rejections and collisions

- Fail if the target branch is already checked out in the current checkout,
  or elsewhere.
- Fail if Git has a stale worktree registration (suggests `git worktree prune`).
- Fail if the destination path already exists.
- Fail if `~/worktrees/<project>` is itself a git repo.
- Detect `/ -> ^` slug collisions and fail clearly.

### Output

- On success, print only the final `~/worktrees/...` path.
- Cleanup guidance uses absolute paths for copy-paste safety.

## Shared path helper

Path logic is centralized in [`lib/git-worktree-paths.sh`](../lib/git-worktree-paths.sh):
canonical repo root resolution, project-name derivation, branch slugging,
centralized target path generation, and `~/worktrees` path classification.

## `trunkyard status` / `trunkyard pull` (`gwss` / `gwp`)

### General scanning

- Outside `~/worktrees`, scan only one level deep below the given path.

### Special handling for `~/worktrees`

When the resolved base path is exactly `$HOME/worktrees`:

- scan direct repos at `~/worktrees/<project>`
- scan nested repos at `~/worktrees/<project>/<branch>`
- do not scan deeper than two levels

### `trunkyard status ~/worktrees`

Prints two separate tables — `Direct Repos` and `Nested Worktrees` — omitting
empty sections, with one combined summary line. Sectioning is presentation
only.

### `trunkyard pull ~/worktrees`

Follows the same ordering as `status`: direct repos first, then nested
worktrees, path-sorted within each category, with per-repo locking.

## Tests

Integration coverage lives in [`tests/integration.sh`](../tests/integration.sh)
(real temporary repos): existing local branches, remote-only branches, new
branches from the current branch, duplicate branch handling, stale
registrations, cleanup guidance, slash remotes, local upstreams,
separate-git-dir repos, `~/worktrees` scanning and ordering, bare repos, and
Bash 3 compatibility. Dispatcher routing, help/version, and symlinked
invocation are covered by [`tests/dispatcher.sh`](../tests/dispatcher.sh).

## Relationship to worktrunk

`trunkyard new` predates and coexists with [worktrunk](https://github.com/max-sixty/worktrunk)
(`wt`): both can target `~/worktrees/<project>/<branch>` layouts, but
trunkyard slugs `/` as `^` where worktrunk sanitizes to `-`, and trunkyard
hard-errors on branches already checked out elsewhere where worktrunk
switches to them. They manage their own worktrees independently; `status` and
`pull` scan both kinds.
