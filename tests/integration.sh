#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null
  pwd -P
)"

NEW_WORKTREE_SCRIPT="$ROOT_DIR/libexec/git-new-worktree.sh"
WORKSPACE_SCRIPT="$ROOT_DIR/libexec/git-workspace.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-worktree-tests.XXXXXX")"
PASS_COUNT=0

cleanup() {
  rm -rf "$TEST_ROOT"
}

trap cleanup EXIT INT TERM

export HOME="$TEST_ROOT/home"
export XDG_CACHE_HOME="$TEST_ROOT/cache"
export GIT_CONFIG_GLOBAL="$TEST_ROOT/home/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="Dotfiles Test"
export GIT_AUTHOR_EMAIL="dotfiles-tests@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$GIT_CONFIG_GLOBAL"
git config --global init.defaultBranch main >/dev/null

abs_dir() {
  (
    cd "$1" 2>/dev/null
    pwd -P
  )
}

worktrees_root_abs() {
  printf '%s/worktrees\n' "$(abs_dir "$HOME")"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_path_exists() {
  local path="$1"
  [[ -e "$path" ]] || fail "expected path to exist: $path"
}

assert_path_missing() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected path to be absent: $path"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected output to contain: %s\n' "$needle" >&2
    printf 'Actual output:\n%s\n' "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'Expected output to not contain: %s\n' "$needle" >&2
    printf 'Actual output:\n%s\n' "$haystack" >&2
    exit 1
  fi
}

assert_eq() {
  local actual="$1"
  local expected="$2"

  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected: %s\n' "$expected" >&2
    printf 'Actual: %s\n' "$actual" >&2
    exit 1
  fi
}

assert_order() {
  local haystack="$1"
  local first="$2"
  local second="$3"
  local first_line=""
  local second_line=""

  first_line="$(grep -n -F "$first" <<<"$haystack" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -n -F "$second" <<<"$haystack" | head -n 1 | cut -d: -f1)"

  [[ -n "$first_line" ]] || fail "missing first marker: $first"
  [[ -n "$second_line" ]] || fail "missing second marker: $second"
  (( first_line < second_line )) || fail "expected '$first' before '$second'"
}

assert_local_branch_exists() {
  local repo="$1"
  local branch="$2"

  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || fail "expected local branch to exist: $branch"
}

assert_local_branch_missing() {
  local repo="$1"
  local branch="$2"

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "expected local branch to be absent: $branch"
  fi
}

assert_remote_fetch_refspec_present() {
  local repo="$1"
  local remote="$2"
  local branch="$3"
  local expected="+refs/heads/$branch:refs/remotes/$remote/$branch"
  local actual=""

  actual="$(git -C "$repo" config --get-all "remote.$remote.fetch" 2>/dev/null || true)"
  grep -Fxq "$expected" <<<"$actual" || fail "expected remote fetch refspec to exist: $expected"
}

shell_escape() {
  printf '%q' "$1"
}

create_repo() {
  local repo="$1"
  local branch="$2"

  mkdir -p "$repo"
  git init -b "$branch" "$repo" >/dev/null
  printf 'seed\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Initial commit" >/dev/null
}

create_remote_only_branch_clone() {
  local workspace="$1"
  local base_branch="$2"
  local remote_branch="$3"
  local remote_name="${4:-origin}"
  local remote_branch_slug="${remote_branch//\//^}"
  local remote_repo="$workspace/${remote_name//\//-}.git"
  local seed_repo="$workspace/seed"
  local clone_repo="$workspace/clone"

  git init --bare "$remote_repo" >/dev/null
  create_repo "$seed_repo" "$base_branch"

  git -C "$seed_repo" remote add "$remote_name" "$remote_repo"
  git -C "$seed_repo" push -u "$remote_name" "$base_branch" >/dev/null

  git -C "$seed_repo" switch -c "$remote_branch" >/dev/null
  printf '%s\n' "$remote_branch" >"$seed_repo/$remote_branch_slug.txt"
  git -C "$seed_repo" add "$remote_branch_slug.txt"
  git -C "$seed_repo" commit -m "Add $remote_branch" >/dev/null
  git -C "$seed_repo" push -u "$remote_name" "$remote_branch" >/dev/null

  git clone --single-branch --branch "$base_branch" "$remote_repo" "$clone_repo" >/dev/null
  if [[ "$remote_name" != "origin" ]]; then
    git -C "$clone_repo" remote rename origin "$remote_name" >/dev/null
  fi
  printf '%s\n' "$clone_repo"
}

create_separate_git_dir_repo() {
  local workspace="$1"
  local repo="$workspace/wt/app"
  local git_dir="$workspace/repos/shared-store.git"

  mkdir -p "$workspace/wt" "$workspace/repos"
  git init --separate-git-dir "$git_dir" "$repo" >/dev/null
  printf 'seed\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Initial commit" >/dev/null

  printf '%s\n' "$repo"
}

create_ambiguous_remote_only_branch_clone() {
  local workspace="$1"
  local base_branch="$2"
  local remote_branch="$3"
  local origin_repo="$workspace/origin.git"
  local upstream_repo="$workspace/upstream.git"
  local seed_repo="$workspace/seed"
  local clone_repo="$workspace/clone"

  git init --bare "$origin_repo" >/dev/null
  git init --bare "$upstream_repo" >/dev/null
  create_repo "$seed_repo" "$base_branch"

  git -C "$seed_repo" remote add origin "$origin_repo"
  git -C "$seed_repo" remote add upstream "$upstream_repo"
  git -C "$seed_repo" push -u origin "$base_branch" >/dev/null
  git -C "$seed_repo" push -u upstream "$base_branch" >/dev/null

  git -C "$seed_repo" switch -c "$remote_branch" >/dev/null
  printf '%s\n' "$remote_branch" >"$seed_repo/ambiguous-branch.txt"
  git -C "$seed_repo" add ambiguous-branch.txt
  git -C "$seed_repo" commit -m "Add $remote_branch to both remotes" >/dev/null
  git -C "$seed_repo" push -u origin "$remote_branch" >/dev/null
  git -C "$seed_repo" push -u upstream "$remote_branch" >/dev/null

  git clone --single-branch --branch "$base_branch" "$origin_repo" "$clone_repo" >/dev/null
  git -C "$clone_repo" remote add upstream "$upstream_repo"
  printf '%s\n' "$clone_repo"
}

create_legacy_repo_local_container() {
  local workspace="$1"
  local base_branch="$2"
  local linked_branch="$3"
  local source_repo="$workspace/source"
  local container_dir="$workspace/foo"
  local main_checkout="$container_dir/${base_branch//\//^}"
  local linked_checkout="$container_dir/${linked_branch//\//^}"

  create_repo "$source_repo" "$base_branch"
  mkdir -p "$container_dir"
  mv "$source_repo" "$main_checkout"
  : >"$container_dir/.git-worktree-container"
  git -C "$main_checkout" worktree add "$linked_checkout" -b "$linked_branch" >/dev/null

  printf '%s\n%s\n' "$main_checkout" "$linked_checkout"
}

run_test() {
  local name="$1"

  echo "==> $name"
  rm -rf "$HOME/worktrees"
  "$name"
  PASS_COUNT=$((PASS_COUNT + 1))
}

test_gwt_creates_centralized_worktree_for_existing_local_branch() {
  local workspace="$TEST_ROOT/workspace-local"
  local repo="$workspace/app"
  local expected_path="$HOME/worktrees/app/feature^test"
  local output=""
  local head_branch=""

  create_repo "$repo" main
  git -C "$repo" switch -c feature/test >/dev/null
  git -C "$repo" switch main >/dev/null

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test
  )"

  assert_eq "$output" "~/worktrees/app/feature^test"
  assert_path_exists "$expected_path/.git"
  head_branch="$(git -C "$expected_path" symbolic-ref --quiet --short HEAD)"
  assert_eq "$head_branch" "feature/test"
}

test_gwt_runs_under_system_bash_3() {
  local workspace="$TEST_ROOT/workspace-system-bash"
  local repo="$workspace/app"
  local expected_path="$HOME/worktrees/app/feature^test"
  local output=""

  [[ -x /bin/bash ]] || return 0

  create_repo "$repo" main
  git -C "$repo" switch -c feature/test >/dev/null
  git -C "$repo" switch main >/dev/null

  output="$(
    cd "$repo"
    /bin/bash "$NEW_WORKTREE_SCRIPT" feature/test
  )"

  assert_eq "$output" "~/worktrees/app/feature^test"
  assert_path_exists "$expected_path/.git"
}

test_gwt_creates_missing_branch_from_current_branch() {
  local workspace="$TEST_ROOT/workspace-new-branch"
  local repo="$workspace/app"
  local expected_path="$HOME/worktrees/app/feature^login"
  local output=""
  local source_head=""
  local worktree_head=""

  create_repo "$repo" main
  printf 'extra\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Advance main" >/dev/null
  source_head="$(git -C "$repo" rev-parse HEAD)"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/login
  )"

  assert_eq "$output" "~/worktrees/app/feature^login"
  assert_local_branch_exists "$repo" "feature/login"
  worktree_head="$(git -C "$expected_path" rev-parse HEAD)"
  assert_eq "$worktree_head" "$source_head"
}

test_gwt_uses_remote_only_branch_and_sets_tracking() {
  local workspace="$TEST_ROOT/workspace-remote-only"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "origin/release"
  assert_remote_fetch_refspec_present "$repo" origin release
}

test_gwt_uses_remote_only_branch_when_fetch_refspec_already_exists() {
  local workspace="$TEST_ROOT/workspace-remote-only-refspec"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" config --add "remote.origin.fetch" "+refs/heads/release:refs/remotes/origin/release"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
}

test_gwt_remote_query_failure_does_not_fallback_to_current_branch() {
  local workspace="$TEST_ROOT/workspace-remote-query-failure"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" update-ref -d refs/remotes/origin/release >/dev/null
  git -C "$repo" config remote.origin.url "$workspace/missing-origin.git"

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release 2>&1
  )"; then
    fail "expected remote query failure to abort"
  fi

  assert_contains "$output" "failed to query remotes for branch 'release'"
  assert_local_branch_missing "$repo" "release"
  assert_path_missing "$expected_path"
}

test_gwt_uses_existing_remote_tracking_ref_when_remote_is_unreachable() {
  local workspace="$TEST_ROOT/workspace-remote-tracking-offline"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" config remote.origin.url "$workspace/missing-origin.git"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "origin/release"
}

test_gwt_refreshes_cached_remote_tracking_ref_before_creation() {
  local workspace="$TEST_ROOT/workspace-remote-tracking-refresh"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local old_remote_head=""
  local new_remote_head=""
  local worktree_head=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  old_remote_head="$(git -C "$repo" rev-parse refs/remotes/origin/release)"

  git -C "$workspace/seed" switch release >/dev/null
  printf 'fresh\n' >>"$workspace/seed/release.txt"
  git -C "$workspace/seed" add release.txt
  git -C "$workspace/seed" commit -m "Advance release" >/dev/null
  git -C "$workspace/seed" push >/dev/null
  new_remote_head="$(git -C "$workspace/seed" rev-parse HEAD)"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
  worktree_head="$(git -C "$expected_path" rev-parse HEAD)"
  assert_eq "$worktree_head" "$new_remote_head"
  [[ "$worktree_head" != "$old_remote_head" ]] || fail "expected refreshed remote head, not stale cached ref"
}

test_gwt_rejects_stale_cached_remote_ref_when_live_remote_says_branch_is_gone() {
  local workspace="$TEST_ROOT/workspace-stale-cached-remote-ref"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" remote add upstream "$workspace/missing-upstream.git"
  git -C "$workspace/seed" push origin --delete release >/dev/null

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release 2>&1
  )"; then
    fail "expected stale cached remote ref plus broken unrelated remote to fail"
  fi

  assert_contains "$output" "failed to query remotes for branch 'release'"
  assert_local_branch_missing "$repo" "release"
  assert_path_missing "$expected_path"
}

test_gwt_ignores_stale_cached_ambiguous_remote_refs_when_live_query_is_unique() {
  local workspace="$TEST_ROOT/workspace-stale-ambiguous-cached-remotes"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""

  repo="$(create_ambiguous_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" fetch upstream "refs/heads/release:refs/remotes/upstream/release" >/dev/null
  git -C "$workspace/seed" push upstream --delete release >/dev/null

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "origin/release"
}

test_gwt_rejects_when_only_unreachable_cached_remote_still_has_stale_ref() {
  local workspace="$TEST_ROOT/workspace-stale-cached-unreachable-only"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" remote rename origin broken >/dev/null
  git -C "$repo" remote add origin "$workspace/live-origin.git"
  git init --bare "$workspace/live-origin.git" >/dev/null
  git -C "$repo" fetch broken "refs/heads/release:refs/remotes/broken/release" >/dev/null
  git -C "$workspace/seed" push origin --delete release >/dev/null
  git -C "$repo" config remote.broken.url "$workspace/missing-broken.git"

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release 2>&1
  )"; then
    fail "expected unreachable-only stale cached remote to fail"
  fi

  assert_contains "$output" "failed to query remotes for branch 'release'"
  assert_local_branch_missing "$repo" "release"
  assert_path_missing "$expected_path"
}

test_gwt_rejects_cached_remote_fallback_when_other_candidate_remotes_are_unreachable() {
  local workspace="$TEST_ROOT/workspace-stale-cached-unreachable-ambiguous"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""

  repo="$(create_ambiguous_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" config remote.origin.url "$workspace/missing-origin.git"
  git -C "$repo" config remote.upstream.url "$workspace/missing-upstream.git"

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release 2>&1
  )"; then
    fail "expected cached remote fallback with other unreachable candidate remotes to fail"
  fi

  assert_contains "$output" "failed to query remotes for branch 'release'"
  assert_local_branch_missing "$repo" "release"
  assert_path_missing "$expected_path"
}

test_gwt_uses_unique_reachable_remote_even_if_another_remote_is_broken() {
  local workspace="$TEST_ROOT/workspace-broken-extra-remote"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" remote add upstream "$workspace/missing-upstream.git"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "origin/release"
}

test_gwt_remote_name_with_slash_preserves_tracking() {
  local workspace="$TEST_ROOT/workspace-remote-name-slash"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""

  repo="$(create_remote_only_branch_clone "$workspace" main release "foo/bar")"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  assert_path_exists "$expected_path/.git"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "foo/bar/release"
  assert_remote_fetch_refspec_present "$repo" "foo/bar" release
}

test_gws_and_gwp_support_remote_names_with_slashes() {
  local workspace="$TEST_ROOT/workspace-slash-remote-workspace"
  local repo=""
  local output=""

  repo="$(create_remote_only_branch_clone "$workspace" main release "foo/bar")"
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release >/dev/null
  )

  output="$(bash "$WORKSPACE_SCRIPT" status "$HOME/worktrees" )"
  assert_contains "$output" "foo/bar/release"
  assert_not_contains "$output" $'\x1ffetch-error\x1f'
  assert_not_contains "$output" " fetch-error "

  output="$(bash "$WORKSPACE_SCRIPT" pull "$HOME/worktrees" --no-fetch)"
  assert_contains "$output" "==> clone/release"
  assert_not_contains "$output" "FAIL: fetch"
}

test_gwt_existing_local_branch_recovers_upstream_when_unique_remote_exists() {
  local workspace="$TEST_ROOT/workspace-existing-local-upstream"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" switch -c release refs/remotes/origin/release >/dev/null
  git -C "$repo" config --unset-all branch.release.remote >/dev/null 2>&1 || true
  git -C "$repo" config --unset-all branch.release.merge >/dev/null 2>&1 || true
  git -C "$repo" switch main >/dev/null

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "origin/release"
  assert_remote_fetch_refspec_present "$repo" origin release
}

test_gwt_existing_local_branch_recovers_from_partial_tracking_config() {
  local workspace="$TEST_ROOT/workspace-existing-local-partial-upstream"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""
  local tracked_remote=""
  local tracked_merge=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" switch -c release refs/remotes/origin/release >/dev/null
  git -C "$repo" config --unset-all branch.release.merge >/dev/null 2>&1 || true
  git -C "$repo" switch main >/dev/null

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "origin/release"
  tracked_remote="$(git -C "$repo" config --get "branch.release.remote")"
  tracked_merge="$(git -C "$repo" config --get "branch.release.merge")"
  assert_eq "$tracked_remote" "origin"
  assert_eq "$tracked_merge" "refs/heads/release"
}

test_gwt_existing_local_branch_preserves_local_upstream() {
  local workspace="$TEST_ROOT/workspace-existing-local-local-upstream"
  local repo=""
  local expected_path="$HOME/worktrees/clone/release"
  local output=""
  local upstream=""
  local tracked_remote=""
  local tracked_merge=""

  repo="$(create_remote_only_branch_clone "$workspace" main release)"
  git -C "$repo" fetch origin "refs/heads/release:refs/remotes/origin/release" >/dev/null
  git -C "$repo" switch -c release refs/remotes/origin/release >/dev/null
  git -C "$repo" config "branch.release.remote" "."
  git -C "$repo" config "branch.release.merge" "refs/heads/main"
  git -C "$repo" switch main >/dev/null

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release
  )"

  assert_eq "$output" "~/worktrees/clone/release"
  upstream="$(git -C "$expected_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  assert_eq "$upstream" "main"
  tracked_remote="$(git -C "$repo" config --get "branch.release.remote")"
  tracked_merge="$(git -C "$repo" config --get "branch.release.merge")"
  assert_eq "$tracked_remote" "."
  assert_eq "$tracked_merge" "refs/heads/main"
}

test_gwt_separate_git_dir_duplicate_guidance_uses_checkout_path() {
  local workspace="$TEST_ROOT/workspace-separate-git-dir-duplicate-guidance"
  local repo=""
  local linked_repo="$workspace/wt/release"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"
  git -C "$repo" worktree add "$linked_repo" -b release >/dev/null

  if output="$(
    cd "$linked_repo"
    bash "$NEW_WORKTREE_SCRIPT" main 2>&1
  )"; then
    fail "expected duplicate main branch guidance to fail"
  fi

  assert_contains "$output" "/workspace-separate-git-dir-duplicate-guidance/wt/app"
  assert_not_contains "$output" "shared-store.git"
}

test_gwt_separate_git_dir_duplicate_guidance_uses_moved_main_checkout_path() {
  local workspace="$TEST_ROOT/workspace-separate-git-dir-duplicate-guidance-moved"
  local repo=""
  local linked_repo="$workspace/other/release-wt"
  local renamed_repo="$workspace/moved/app-renamed"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/seed >/dev/null
  )
  mkdir -p "$workspace/other" "$workspace/moved"
  git -C "$repo" worktree add "$linked_repo" -b release >/dev/null
  mv "$repo" "$renamed_repo"

  if output="$(
    cd "$linked_repo"
    bash "$NEW_WORKTREE_SCRIPT" main 2>&1
  )"; then
    fail "expected moved-main duplicate branch guidance to fail"
  fi

  assert_contains "$output" "/workspace-separate-git-dir-duplicate-guidance-moved/moved/app-renamed"
  assert_not_contains "$output" "shared-store.git"
  assert_not_contains "$output" "/workspace-separate-git-dir-duplicate-guidance-moved/other/release-wt"
}

test_gwt_rejects_ambiguous_remote_only_branch() {
  local workspace="$TEST_ROOT/workspace-ambiguous"
  local repo=""
  local output=""

  repo="$(create_ambiguous_remote_only_branch_clone "$workspace" main release)"

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" release 2>&1
  )"; then
    fail "expected ambiguous remote-only branch to fail"
  fi

  assert_contains "$output" "exists on multiple remotes"
}

test_gwt_duplicate_branch_prints_worktree_remove() {
  local workspace="$TEST_ROOT/workspace-duplicate"
  local repo="$workspace/app"
  local existing_path="$(worktrees_root_abs)/app/feature^test"
  local escaped_existing_path=""
  local output=""

  create_repo "$repo" main
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test >/dev/null
  )

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected duplicate branch checkout to fail"
  fi

  escaped_existing_path="$(shell_escape "$existing_path")"
  assert_contains "$output" "git worktree remove $escaped_existing_path"
}

test_gwt_current_branch_rejects_without_remove_guidance() {
  local workspace="$TEST_ROOT/workspace-current-branch"
  local repo="$workspace/app"
  local output=""

  create_repo "$repo" main
  git -C "$repo" switch -c feature/test >/dev/null

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected current branch case to fail"
  fi

  assert_contains "$output" "already active"
  assert_not_contains "$output" "git worktree remove"
}

test_gwt_main_checkout_branch_rejects_without_remove_guidance() {
  local workspace="$TEST_ROOT/workspace-main-checkout-branch"
  local repo="$workspace/app"
  local sibling="$workspace/release"
  local output=""

  create_repo "$repo" main
  git -C "$repo" switch -c feature/test >/dev/null
  git -C "$repo" worktree add "$sibling" -b release >/dev/null

  if output="$(
    cd "$sibling"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected main checkout branch conflict to fail"
  fi

  assert_contains "$output" "switch that checkout to another branch"
  assert_not_contains "$output" "git worktree remove"
}

test_gwt_stale_branch_worktree_prints_prune() {
  local workspace="$TEST_ROOT/workspace-stale-branch"
  local repo="$workspace/app"
  local stale_path="$HOME/worktrees/app/feature^test"
  local output=""

  create_repo "$repo" main
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test >/dev/null
  )
  rm -rf "$stale_path"
  assert_path_missing "$stale_path"

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected stale worktree registration to fail"
  fi

  assert_contains "$output" "git worktree prune"
}

test_gwt_plain_destination_collision_prints_rm_rf() {
  local workspace="$TEST_ROOT/workspace-occupied-path"
  local repo="$workspace/app"
  local occupied_path="$HOME/worktrees/app/feature^test"
  local occupied_path_abs="$(worktrees_root_abs)/app/feature^test"
  local escaped_occupied_path=""
  local output=""

  create_repo "$repo" main
  mkdir -p "$occupied_path"
  printf 'junk\n' >"$occupied_path/file.txt"

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected occupied destination path to fail"
  fi

  escaped_occupied_path="$(shell_escape "$occupied_path_abs")"
  assert_contains "$output" "rm -rf $escaped_occupied_path"
}

test_gwt_cleanup_guidance_shell_escapes_paths_with_spaces() {
  local workspace="$TEST_ROOT/workspace spaced"
  local repo="$workspace/my app"
  local existing_path_abs="$(worktrees_root_abs)/my app/feature^test"
  local escaped_existing_path=""
  local occupied_path="$HOME/worktrees/my app/feature^other"
  local occupied_path_abs="$(worktrees_root_abs)/my app/feature^other"
  local escaped_occupied_path=""
  local output=""

  create_repo "$repo" main

  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test >/dev/null
  )

  escaped_existing_path="$(shell_escape "$existing_path_abs")"
  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected duplicate branch checkout to fail"
  fi
  assert_contains "$output" "git worktree remove $escaped_existing_path"

  mkdir -p "$occupied_path"
  printf 'junk\n' >"$occupied_path/file.txt"

  escaped_occupied_path="$(shell_escape "$occupied_path_abs")"
  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/other 2>&1
  )"; then
    fail "expected occupied destination path to fail"
  fi
  assert_contains "$output" "rm -rf $escaped_occupied_path"
}

test_gwt_allows_regular_repo_named_like_current_branch() {
  local workspace="$TEST_ROOT/workspace-named-like-branch"
  local repo="$workspace/main"
  local expected_path="$HOME/worktrees/main/feature^test"
  local output=""

  create_repo "$repo" main

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test
  )"

  assert_eq "$output" "~/worktrees/main/feature^test"
  assert_path_exists "$expected_path/.git"
}

test_gwt_uses_repo_name_for_separate_git_dir_checkouts() {
  local workspace="$TEST_ROOT/workspace-separate-git-dir"
  local repo=""
  local linked_repo="$workspace/wt/release"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"

  output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test
  )"
  assert_eq "$output" "~/worktrees/app/feature^test"
  assert_path_exists "$HOME/worktrees/app/feature^test/.git"

  git -C "$repo" worktree add "$linked_repo" -b release >/dev/null
  output="$(
    cd "$linked_repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/next
  )"
  assert_eq "$output" "~/worktrees/app/feature^next"
  assert_path_exists "$HOME/worktrees/app/feature^next/.git"
}

test_gwt_keeps_non_sibling_separate_git_dir_worktrees_in_main_namespace() {
  local workspace="$TEST_ROOT/workspace-separate-git-dir-nonsibling"
  local repo=""
  local linked_repo="$workspace/other/release-wt"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/seed >/dev/null
  )
  mkdir -p "$workspace/other"
  git -C "$repo" worktree add "$linked_repo" -b release >/dev/null

  output="$(
    cd "$linked_repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/next
  )"

  assert_eq "$output" "~/worktrees/app/feature^next"
  assert_path_exists "$HOME/worktrees/app/feature^next/.git"
}

test_gwt_main_checkout_rename_updates_project_namespace() {
  local workspace="$TEST_ROOT/workspace-rename-main-checkout"
  local repo="$workspace/app"
  local renamed_repo="$workspace/app-renamed"
  local output=""

  create_repo "$repo" main
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/seed >/dev/null
  )

  mv "$repo" "$renamed_repo"

  output="$(
    cd "$renamed_repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/next
  )"

  assert_eq "$output" "~/worktrees/app-renamed/feature^next"
  assert_path_exists "$HOME/worktrees/app-renamed/feature^next/.git"
}

test_gwt_linked_worktree_uses_renamed_main_checkout_namespace() {
  local workspace="$TEST_ROOT/workspace-rename-main-from-linked"
  local repo=""
  local linked_repo="$workspace/other/release-wt"
  local renamed_repo="$workspace/moved/app-renamed"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/seed >/dev/null
  )
  mkdir -p "$workspace/other" "$workspace/moved"
  git -C "$repo" worktree add "$linked_repo" -b release >/dev/null
  mv "$repo" "$renamed_repo"

  output="$(
    cd "$linked_repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/next
  )"

  assert_eq "$output" "~/worktrees/app-renamed/feature^next"
  assert_path_exists "$HOME/worktrees/app-renamed/feature^next/.git"
}

test_gwt_centralized_worktree_uses_renamed_main_checkout_namespace() {
  local workspace="$TEST_ROOT/workspace-rename-main-from-centralized"
  local repo=""
  local renamed_repo="$workspace/moved/app-renamed"
  local centralized_repo="$HOME/worktrees/app/feature^seed"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/seed >/dev/null
  )
  mkdir -p "$workspace/moved"
  mv "$repo" "$renamed_repo"

  output="$(
    cd "$centralized_repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/next
  )"

  assert_eq "$output" "~/worktrees/app-renamed/feature^next"
  assert_path_exists "$HOME/worktrees/app-renamed/feature^next/.git"
}

test_gwt_linked_worktree_errors_when_main_checkout_cannot_be_recovered() {
  local workspace="$TEST_ROOT/workspace-unrecoverable-main-move"
  local repo=""
  local linked_repo="$workspace/other/release-wt"
  local moved_repo="$TEST_ROOT/outside-root/app-renamed"
  local output=""

  repo="$(create_separate_git_dir_repo "$workspace")"
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/seed >/dev/null
  )
  mkdir -p "$workspace/other" "$(dirname "$moved_repo")"
  git -C "$repo" worktree add "$linked_repo" -b release >/dev/null
  mv "$repo" "$moved_repo"

  if output="$(
    cd "$linked_repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/next 2>&1
  )"; then
    fail "expected unrecoverable separate-git-dir main checkout move to fail"
  fi

  assert_contains "$output" "cannot resolve the main checkout for this separate-git-dir repo"
  assert_path_missing "$HOME/worktrees/app/feature^next"
  assert_path_missing "$HOME/worktrees/app-renamed/feature^next"
}

test_gwt_rejects_legacy_repo_local_container_layouts() {
  local workspace="$TEST_ROOT/workspace-legacy-container"
  local main_checkout=""
  local linked_checkout=""
  local output=""

  legacy_paths=()
  while IFS= read -r path; do
    legacy_paths+=("$path")
  done < <(create_legacy_repo_local_container "$workspace" main feature/old)
  main_checkout="${legacy_paths[0]}"
  linked_checkout="${legacy_paths[1]}"

  if output="$(
    cd "$main_checkout"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected legacy main checkout to fail"
  fi

  assert_contains "$output" "legacy repo-local container layouts are no longer supported"

  git -C "$main_checkout" switch -c release >/dev/null
  if output="$(
    cd "$main_checkout"
    bash "$NEW_WORKTREE_SCRIPT" feature/after-switch 2>&1
  )"; then
    fail "expected switched legacy main checkout to still fail"
  fi

  assert_contains "$output" "legacy repo-local container layouts are no longer supported"

  if output="$(
    cd "$linked_checkout"
    bash "$NEW_WORKTREE_SCRIPT" feature/new 2>&1
  )"; then
    fail "expected legacy linked checkout to fail"
  fi

  assert_contains "$output" "legacy repo-local container layouts are no longer supported"
}

test_gwt_allows_normal_sibling_worktree_layouts() {
  local workspace="$TEST_ROOT/workspace-normal-sibling"
  local repo="$workspace/main"
  local sibling="$workspace/feature^old"
  local expected_path="$HOME/worktrees/main/feature^new"
  local output=""

  create_repo "$repo" main
  git -C "$repo" worktree add "$sibling" -b feature/old >/dev/null

  output="$(
    cd "$sibling"
    bash "$NEW_WORKTREE_SCRIPT" feature/new
  )"

  assert_eq "$output" "~/worktrees/main/feature^new"
  assert_path_exists "$expected_path/.git"
}

test_gwt_same_basename_repo_collision_does_not_suggest_rm_rf() {
  local workspace_a="$TEST_ROOT/workspace-same-name-a"
  local workspace_b="$TEST_ROOT/workspace-same-name-b"
  local repo_a="$workspace_a/app"
  local repo_b="$workspace_b/app"
  local output=""

  create_repo "$repo_a" main
  create_repo "$repo_b" main

  (
    cd "$repo_a"
    bash "$NEW_WORKTREE_SCRIPT" feature/test >/dev/null
  )

  if output="$(
    cd "$repo_b"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected same-basename namespace collision to fail"
  fi

  assert_contains "$output" "occupied by another git repo"
  assert_not_contains "$output" "rm -rf"
}

test_gwt_rejects_when_project_dir_is_git_repo() {
  local workspace="$TEST_ROOT/workspace-project-dir-repo"
  local repo="$workspace/app"
  local direct_repo="$HOME/worktrees/app"
  local output=""

  create_repo "$repo" main
  create_repo "$direct_repo" main

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected project dir repo collision to fail"
  fi

  assert_contains "$output" "is itself a git repo"
}

test_gwt_rejects_when_project_dir_is_bare_repo() {
  local workspace="$TEST_ROOT/workspace-project-dir-bare-repo"
  local repo="$workspace/app"
  local project_dir="$HOME/worktrees/app"
  local output=""

  create_repo "$repo" main
  mkdir -p "$HOME/worktrees"
  git init --bare "$project_dir" >/dev/null

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected bare project dir to fail"
  fi

  assert_contains "$output" "is itself a git repo"
  assert_path_missing "$project_dir/feature^test"
}

test_gwt_rejects_when_run_from_direct_repo_under_worktrees() {
  local repo="$HOME/worktrees/app"
  local output=""

  create_repo "$repo" main

  if output="$(
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test 2>&1
  )"; then
    fail "expected direct repo under ~/worktrees to fail"
  fi

  assert_contains "$output" "cannot create nested worktrees from direct repo"
}

test_gws_worktrees_shows_direct_and_nested_sections() {
  local workspace="$TEST_ROOT/workspace-status"
  local repo="$workspace/app"
  local output=""

  create_repo "$HOME/worktrees/direct" main
  create_repo "$repo" main
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test >/dev/null
  )

  output="$(bash "$WORKSPACE_SCRIPT" status "$HOME/worktrees" --no-fetch)"

  assert_contains "$output" "Direct Repos"
  assert_contains "$output" "Nested Worktrees"
  assert_contains "$output" "direct"
  assert_contains "$output" "app/feature^test"
  assert_order "$output" "Direct Repos" "direct"
  assert_order "$output" "direct" "Nested Worktrees"
  assert_order "$output" "Nested Worktrees" "app/feature^test"
  assert_contains "$output" "repos:2"
}

test_gws_and_gwp_worktrees_preserve_symlink_entry_paths() {
  local workspace="$TEST_ROOT/workspace-symlinked-worktrees"
  local outside_direct="$workspace/outside-direct"
  local nested_target_root="$workspace/outside-nested-root"
  local output=""

  create_repo "$outside_direct" main
  mkdir -p "$nested_target_root"
  create_repo "$nested_target_root/feature^test" main

  mkdir -p "$HOME/worktrees"
  ln -s "$outside_direct" "$HOME/worktrees/direct-link"
  ln -s "$nested_target_root" "$HOME/worktrees/app-link"

  output="$(bash "$WORKSPACE_SCRIPT" status "$HOME/worktrees" --no-fetch)"
  assert_contains "$output" "Direct Repos"
  assert_contains "$output" "Nested Worktrees"
  assert_contains "$output" "direct-link"
  assert_contains "$output" "app-link/feature^test"
  assert_not_contains "$output" "$outside_direct"
  assert_not_contains "$output" "$nested_target_root"

  output="$(bash "$WORKSPACE_SCRIPT" pull "$HOME/worktrees" --no-fetch)"
  assert_contains "$output" "==> direct-link"
  assert_contains "$output" "==> app-link/feature^test"
  assert_not_contains "$output" "$outside_direct"
  assert_not_contains "$output" "$nested_target_root"
}

test_gws_worktrees_skips_child_repos_under_direct_repo() {
  local output=""

  create_repo "$HOME/worktrees/direct" main
  create_repo "$HOME/worktrees/direct/vendor" main

  output="$(bash "$WORKSPACE_SCRIPT" status "$HOME/worktrees" --no-fetch)"

  assert_contains "$output" "Direct Repos"
  assert_contains "$output" "direct"
  assert_not_contains "$output" "vendor"
  assert_not_contains "$output" "Nested Worktrees"
  assert_contains "$output" "repos:1"
}

test_gws_outside_worktrees_stays_one_level() {
  local workspace="$TEST_ROOT/workspace-one-level"
  local nested_repo="$workspace/cache/repo"
  local output=""

  create_repo "$nested_repo" main
  output="$(bash "$WORKSPACE_SCRIPT" status "$workspace" --no-fetch)"

  assert_contains "$output" "No git repos found."
}

test_gws_outside_worktrees_shows_bare_repo_as_bare_repo() {
  local workspace="$TEST_ROOT/workspace-bare-repo-status"
  local output=""

  mkdir -p "$workspace"
  git init --bare "$workspace/bare.git" >/dev/null

  output="$(bash "$WORKSPACE_SCRIPT" status "$workspace" --no-fetch)"

  assert_contains "$output" "bare.git"
  assert_contains "$output" "bare-repo"
  assert_not_contains "$output" "status-error"
}

test_gws_and_gwp_run_under_system_bash_3() {
  local workspace="$TEST_ROOT/workspace-system-bash-workspace"
  local repo="$workspace/app"
  local output=""

  [[ -x /bin/bash ]] || return 0

  create_repo "$repo" main

  output="$(/bin/bash "$WORKSPACE_SCRIPT" status "$workspace" --no-fetch 2>&1)"
  assert_contains "$output" "app"
  assert_not_contains "$output" "declare: -g"
  assert_not_contains "$output" "invalid option"

  output="$(/bin/bash "$WORKSPACE_SCRIPT" pull "$workspace" --no-fetch 2>&1)"
  assert_contains "$output" "==> app"
  assert_not_contains "$output" "unbound variable"

  output="$(/bin/bash "$WORKSPACE_SCRIPT" --help 2>&1)"
  assert_contains "$output" "git-workspace.sh status"
  assert_not_contains "$output" "unbound variable"
}

test_gwp_supports_local_upstream_tracking() {
  local workspace="$TEST_ROOT/workspace-local-upstream-pull"
  local repo="$workspace/repo"
  local linked_repo="$workspace/release-wt"
  local output=""
  local main_head=""
  local release_head=""

  create_repo "$repo" main
  git -C "$repo" switch -c release >/dev/null
  git -C "$repo" config "branch.release.remote" "."
  git -C "$repo" config "branch.release.merge" "refs/heads/main"
  git -C "$repo" switch main >/dev/null
  git -C "$repo" worktree add "$linked_repo" release >/dev/null

  printf 'advance\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Advance main" >/dev/null
  main_head="$(git -C "$repo" rev-parse HEAD)"

  output="$(bash "$WORKSPACE_SCRIPT" pull "$workspace" 2>&1)"

  assert_contains "$output" "==> release-wt"
  assert_not_contains "$output" "not something we can merge"
  release_head="$(git -C "$linked_repo" rev-parse HEAD)"
  assert_eq "$release_head" "$main_head"
}

test_gws_and_gwp_support_local_upstream_named_like_remote_path() {
  local workspace="$TEST_ROOT/workspace-local-upstream-remote-like"
  local repo="$workspace/repo"
  local linked_repo="$workspace/release-wt"
  local output=""
  local target_head=""
  local release_head=""

  create_repo "$repo" main
  git -C "$repo" switch -c origin/fix >/dev/null
  git -C "$repo" switch -c release >/dev/null
  git -C "$repo" config "branch.release.remote" "."
  git -C "$repo" config "branch.release.merge" "refs/heads/origin/fix"
  git -C "$repo" switch origin/fix >/dev/null
  printf 'advance\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Advance local origin/fix" >/dev/null
  target_head="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" switch main >/dev/null
  git -C "$repo" worktree add "$linked_repo" release >/dev/null

  output="$(bash "$WORKSPACE_SCRIPT" status "$workspace" 2>&1)"
  assert_contains "$output" "origin/fix"
  assert_not_contains "$output" " fetch-error "
  assert_not_contains "$output" "fetch-errors:1"
  assert_contains "$output" "behind:1"

  output="$(bash "$WORKSPACE_SCRIPT" pull "$workspace" 2>&1)"
  assert_not_contains "$output" "FAIL: fetch"
  assert_not_contains "$output" "not something we can merge"
  release_head="$(git -C "$linked_repo" rev-parse HEAD)"
  assert_eq "$release_head" "$target_head"
}

test_gws_worktrees_includes_bare_direct_repos() {
  local output=""

  mkdir -p "$HOME/worktrees"
  git init --bare "$HOME/worktrees/bare-direct" >/dev/null

  output="$(bash "$WORKSPACE_SCRIPT" status "$HOME/worktrees" --no-fetch)"

  assert_contains "$output" "Direct Repos"
  assert_contains "$output" "bare-direct"
  assert_not_contains "$output" "No git repos found."

  output="$(bash "$WORKSPACE_SCRIPT" pull "$HOME/worktrees" 2>&1)"
  assert_contains "$output" "==> bare-direct"
  assert_contains "$output" "SKIP: bare repo"
  assert_not_contains "$output" "FAIL: status-error"
}

test_gwp_worktrees_skips_symlinked_bare_repos() {
  local workspace="$TEST_ROOT/workspace-symlink-bare-worktrees"
  local real_bare="$workspace/real-bare.git"
  local output=""

  mkdir -p "$workspace" "$HOME/worktrees"
  git init --bare "$real_bare" >/dev/null
  ln -s "$real_bare" "$HOME/worktrees/bare-link"

  output="$(bash "$WORKSPACE_SCRIPT" pull "$HOME/worktrees" 2>&1)"

  assert_contains "$output" "==> bare-link"
  assert_contains "$output" "SKIP: bare repo"
  assert_not_contains "$output" "FAIL: status-error"
}

test_gwp_worktrees_processes_direct_before_nested() {
  local workspace="$TEST_ROOT/workspace-pull-order"
  local repo="$workspace/zzz"
  local output=""

  create_repo "$HOME/worktrees/aaa" main
  create_repo "$repo" main
  (
    cd "$repo"
    bash "$NEW_WORKTREE_SCRIPT" feature/test >/dev/null
  )

  output="$(bash "$WORKSPACE_SCRIPT" pull "$HOME/worktrees" --no-fetch)"

  assert_order "$output" "==> aaa" "==> zzz/feature^test"
}

test_gwp_worktrees_processes_all_direct_before_nested() {
  local output=""

  create_repo "$HOME/worktrees/zzz" main
  mkdir -p "$HOME/worktrees/aaa-proj"
  create_repo "$HOME/worktrees/aaa-proj/feature" main

  output="$(bash "$WORKSPACE_SCRIPT" pull "$HOME/worktrees" --no-fetch)"

  assert_order "$output" "==> zzz" "==> aaa-proj/feature"
}

run_test test_gwt_creates_centralized_worktree_for_existing_local_branch
run_test test_gwt_runs_under_system_bash_3
run_test test_gwt_creates_missing_branch_from_current_branch
run_test test_gwt_uses_remote_only_branch_and_sets_tracking
run_test test_gwt_uses_remote_only_branch_when_fetch_refspec_already_exists
run_test test_gwt_remote_query_failure_does_not_fallback_to_current_branch
run_test test_gwt_uses_existing_remote_tracking_ref_when_remote_is_unreachable
run_test test_gwt_refreshes_cached_remote_tracking_ref_before_creation
run_test test_gwt_rejects_stale_cached_remote_ref_when_live_remote_says_branch_is_gone
run_test test_gwt_ignores_stale_cached_ambiguous_remote_refs_when_live_query_is_unique
run_test test_gwt_rejects_when_only_unreachable_cached_remote_still_has_stale_ref
run_test test_gwt_rejects_cached_remote_fallback_when_other_candidate_remotes_are_unreachable
run_test test_gwt_uses_unique_reachable_remote_even_if_another_remote_is_broken
run_test test_gwt_remote_name_with_slash_preserves_tracking
run_test test_gws_and_gwp_support_remote_names_with_slashes
run_test test_gwt_existing_local_branch_recovers_upstream_when_unique_remote_exists
run_test test_gwt_existing_local_branch_recovers_from_partial_tracking_config
run_test test_gwt_existing_local_branch_preserves_local_upstream
run_test test_gwt_separate_git_dir_duplicate_guidance_uses_checkout_path
run_test test_gwt_separate_git_dir_duplicate_guidance_uses_moved_main_checkout_path
run_test test_gwt_rejects_ambiguous_remote_only_branch
run_test test_gwt_duplicate_branch_prints_worktree_remove
run_test test_gwt_current_branch_rejects_without_remove_guidance
run_test test_gwt_main_checkout_branch_rejects_without_remove_guidance
run_test test_gwt_stale_branch_worktree_prints_prune
run_test test_gwt_plain_destination_collision_prints_rm_rf
run_test test_gwt_cleanup_guidance_shell_escapes_paths_with_spaces
run_test test_gwt_allows_regular_repo_named_like_current_branch
run_test test_gwt_uses_repo_name_for_separate_git_dir_checkouts
run_test test_gwt_keeps_non_sibling_separate_git_dir_worktrees_in_main_namespace
run_test test_gwt_main_checkout_rename_updates_project_namespace
run_test test_gwt_linked_worktree_uses_renamed_main_checkout_namespace
run_test test_gwt_centralized_worktree_uses_renamed_main_checkout_namespace
run_test test_gwt_linked_worktree_errors_when_main_checkout_cannot_be_recovered
run_test test_gwt_rejects_legacy_repo_local_container_layouts
run_test test_gwt_allows_normal_sibling_worktree_layouts
run_test test_gwt_same_basename_repo_collision_does_not_suggest_rm_rf
run_test test_gwt_rejects_when_project_dir_is_git_repo
run_test test_gwt_rejects_when_project_dir_is_bare_repo
run_test test_gwt_rejects_when_run_from_direct_repo_under_worktrees
run_test test_gws_worktrees_shows_direct_and_nested_sections
run_test test_gws_and_gwp_worktrees_preserve_symlink_entry_paths
run_test test_gws_worktrees_skips_child_repos_under_direct_repo
run_test test_gws_outside_worktrees_stays_one_level
run_test test_gws_outside_worktrees_shows_bare_repo_as_bare_repo
run_test test_gws_and_gwp_run_under_system_bash_3
run_test test_gwp_supports_local_upstream_tracking
run_test test_gws_and_gwp_support_local_upstream_named_like_remote_path
run_test test_gws_worktrees_includes_bare_direct_repos
run_test test_gwp_worktrees_skips_symlinked_bare_repos
run_test test_gwp_worktrees_processes_direct_before_nested
run_test test_gwp_worktrees_processes_all_direct_before_nested

printf 'PASS: %d tests\n' "$PASS_COUNT"
