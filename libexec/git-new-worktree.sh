#!/usr/bin/env bash
set -euo pipefail

script_name="$(basename "$0")"
script_dir="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null
  pwd -P
)"

# shellcheck source=/dev/null
source "$script_dir/../lib/git-worktree-paths.sh"

resolved_remote_name=""
resolved_remote_branch=""

usage() {
  cat <<'EOF'
Usage:
  git-new-worktree.sh <branch>

Examples:
  git-new-worktree.sh feature/login
  git-new-worktree.sh release

Behavior:
  - Must be run inside a git checkout.
  - Creates worktrees only under ~/worktrees/<project>/<branch>.
  - Reuses an existing local branch, resolves a unique remote-only branch, or creates a
    new branch from the current branch in the current checkout.
EOF
}

die() {
  echo "$script_name: $*" >&2
  exit 1
}

shell_escape_path() {
  printf '%q' "$1"
}

config_has_exact_value() {
  local repo="$1"
  local key="$2"
  local value="$3"
  local existing=""

  while IFS= read -r existing; do
    [[ "$existing" == "$value" ]] && return 0
  done < <(git -C "$repo" config --get-all "$key" 2>/dev/null || true)

  return 1
}

is_git_repository_root() {
  local path="$1"
  local path_abs=""
  local top_level=""
  local git_dir=""

  path_abs="$(git_worktree_abs_dir "$path" 2>/dev/null || true)"
  [[ -n "$path_abs" ]] || return 1

  top_level="$(git -C "$path_abs" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$top_level" ]]; then
    [[ "$(git_worktree_abs_dir "$top_level" 2>/dev/null || true)" == "$path_abs" ]] && return 0
  fi

  git_dir="$(git -C "$path_abs" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" && "$git_dir" == "$path_abs" ]]
}

is_main_worktree_path() {
  local repo="$1"
  local path="$2"
  local main_root=""
  local common_dir=""

  main_root="$(git_worktree_authoritative_main_checkout_root "$repo" 2>/dev/null || true)"
  common_dir="$(git_worktree_common_dir_abs "$repo" 2>/dev/null || true)"

  [[ -n "$main_root" && "$path" == "$main_root" ]] && return 0
  [[ -n "$common_dir" && "$path" == "$common_dir" ]] && return 0
  return 1
}

persist_project_name_if_authoritative() {
  local repo="$1"
  local project_name="$2"
  local configured=""
  local rel=""
  local main_root=""
  local configured_main=""
  local parent=""

  configured="$(git_worktree_configured_project_name "$repo")"
  configured_main="$(git_worktree_configured_main_checkout_path "$repo")"

  rel="$(git_worktree_relative_to_root "$repo" 2>/dev/null || true)"
  if [[ -n "$rel" && "$rel" != "." && "${rel%%/*}" == "$project_name" ]]; then
    [[ "$configured" == "$project_name" ]] || git -C "$repo" config "$GIT_WORKTREE_PROJECT_CONFIG_KEY" "$project_name"
    return 0
  fi

  main_root="$(git_worktree_authoritative_main_checkout_root "$repo" 2>/dev/null || true)"
  if [[ -n "$main_root" && "$repo" == "$main_root" && "$(basename "$repo")" == "$project_name" ]]; then
    [[ "$configured" == "$project_name" ]] || git -C "$repo" config "$GIT_WORKTREE_PROJECT_CONFIG_KEY" "$project_name"
    [[ "$configured_main" == "$repo" ]] || git -C "$repo" config "$GIT_WORKTREE_MAIN_CHECKOUT_PATH_CONFIG_KEY" "$repo"
    parent="$(dirname "$repo")"
    config_has_exact_value "$repo" "$GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY" "$parent" || \
      git -C "$repo" config --add "$GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY" "$parent"
    parent="$(dirname "$parent")"
    config_has_exact_value "$repo" "$GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY" "$parent" || \
      git -C "$repo" config --add "$GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY" "$parent"
  fi
}

local_branch_exists() {
  local repo="$1"
  local branch_name="$2"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch_name"
}

remote_exists() {
  local repo="$1"
  local remote_name="$2"
  [[ -n "$remote_name" ]] || return 1
  git -C "$repo" remote get-url "$remote_name" >/dev/null 2>&1
}

ensure_remote_fetch_refspec() {
  local repo="$1"
  local remote_name="$2"
  local branch_name="$3"
  local fetch_refspec="+refs/heads/$branch_name:refs/remotes/$remote_name/$branch_name"
  local configured_refspec=""

  while IFS= read -r configured_refspec; do
    [[ "$configured_refspec" == "$fetch_refspec" ]] && return 10
  done < <(git -C "$repo" config --get-all "remote.$remote_name.fetch" 2>/dev/null || true)

  git -C "$repo" config --add "remote.$remote_name.fetch" "$fetch_refspec"
  return 0
}

append_remote_if_present() {
  local repo="$1"
  local remote_name="$2"

  [[ -n "$remote_name" ]] || return 0
  remote_exists "$repo" "$remote_name" || return 0

  if [[ -n "$candidate_remotes" ]] && grep -Fqx -- "$remote_name" <<<"$candidate_remotes"; then
    return 0
  fi

  candidate_remotes+="$remote_name"$'\n'
}

candidate_remote_list_for_branch_context() {
  local repo="$1"
  local current_branch_name="$2"
  local preferred_remote=""
  local remote_name=""
  local candidate_remotes=""

  preferred_remote="$(git -C "$repo" config --get "branch.$current_branch_name.remote" 2>/dev/null || true)"
  append_remote_if_present "$repo" "$preferred_remote"
  append_remote_if_present "$repo" origin

  while IFS= read -r remote_name; do
    [[ -n "$remote_name" ]] || continue
    append_remote_if_present "$repo" "$remote_name"
  done < <(git -C "$repo" remote)

  printf '%s' "$candidate_remotes"
}

resolve_existing_remote_tracking_branch_if_unique() {
  local repo="$1"
  local current_branch_name="$2"
  local branch_name="$3"
  local remote_name=""
  local candidate_remotes=""
  local match_count=0
  local unique_match=""

  resolved_remote_name=""
  resolved_remote_branch=""

  candidate_remotes="$(candidate_remote_list_for_branch_context "$repo" "$current_branch_name")"

  while IFS= read -r remote_name; do
    [[ -n "$remote_name" ]] || continue
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/$remote_name/$branch_name"; then
      unique_match="$remote_name"
      ((match_count += 1))
    fi
  done <<<"$candidate_remotes"

  if (( match_count == 1 )); then
    resolved_remote_name="$unique_match"
    resolved_remote_branch="$branch_name"
    return 0
  fi

  if (( match_count > 1 )); then
    return 2
  fi

  return 1
}

resolve_remote_branch_if_unique() {
  local repo="$1"
  local current_branch_name="$2"
  local branch_name="$3"
  local candidate_remotes=""
  local remote_name=""
  local cached_matches=""
  local failed_cached_matches=""
  local candidate_remote_count=0
  local cached_match_count=0
  local failed_cached_match_count=0
  local match_count=0
  local verified_no_match_count=0
  local unique_match=""
  local unique_failed_cached_match=""
  local ls_remote_status=0
  local had_query_error=0

  resolved_remote_name=""
  resolved_remote_branch=""

  candidate_remotes="$(candidate_remote_list_for_branch_context "$repo" "$current_branch_name")"

  while IFS= read -r remote_name; do
    [[ -n "$remote_name" ]] || continue
    ((candidate_remote_count += 1))
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/$remote_name/$branch_name"; then
      cached_matches+="$remote_name"$'\n'
      ((cached_match_count += 1))
    fi
  done <<<"$candidate_remotes"

  while IFS= read -r remote_name; do
    [[ -n "$remote_name" ]] || continue
    ls_remote_status=0
    git -C "$repo" ls-remote --exit-code --heads "$remote_name" "refs/heads/$branch_name" >/dev/null 2>&1 || ls_remote_status=$?
    if (( ls_remote_status == 0 )); then
      unique_match="$remote_name"
      matches+="$remote_name"$'\n'
      ((match_count += 1))
      continue
    fi
    if (( ls_remote_status == 2 )); then
      ((verified_no_match_count += 1))
      continue
    fi
    had_query_error=1
    if [[ -n "$cached_matches" ]] && grep -Fqx -- "$remote_name" <<<"$cached_matches"; then
      unique_failed_cached_match="$remote_name"
      failed_cached_matches+="$remote_name"$'\n'
      ((failed_cached_match_count += 1))
    fi
  done <<<"$candidate_remotes"

  if (( match_count == 1 )); then
    git -C "$repo" fetch --no-tags "$unique_match" "refs/heads/$branch_name:refs/remotes/$unique_match/$branch_name" >/dev/null
    resolved_remote_name="$unique_match"
    resolved_remote_branch="$branch_name"
    return 0
  fi

  if (( match_count > 1 )); then
    return 2
  fi

  if (( had_query_error )); then
    # Only trust a cached remote-tracking ref when there is exactly one candidate remote.
    if (( failed_cached_match_count == 1 && candidate_remote_count == 1 )); then
      resolved_remote_name="$unique_failed_cached_match"
      resolved_remote_branch="$branch_name"
      return 0
    fi
    if (( failed_cached_match_count > 1 )); then
      return 3
    fi
  fi

  # If any remote was unreachable and none matched, abort rather than guessing the branch is new.
  if (( had_query_error )); then
    return 3
  fi

  return 1
}

branch_worktree_path() {
  local repo="$1"
  local target="$2"
  local path=""
  local common_dir=""
  local main_root=""

  path="$(git worktree list --porcelain 2>/dev/null | awk -v target="refs/heads/$target" '
    $1 == "worktree" { path = substr($0, 10) }
    $1 == "branch" && $2 == target { print path; exit }
  ')"

  [[ -n "$path" ]] || return 1

  common_dir="$(git_worktree_common_dir_abs "$repo" 2>/dev/null || true)"
  main_root="$(git_worktree_authoritative_main_checkout_root "$repo" 2>/dev/null || true)"
  if [[ -n "$common_dir" && -n "$main_root" && "$path" == "$common_dir" ]]; then
    printf '%s\n' "$main_root"
    return 0
  fi

  printf '%s\n' "$path"
}

registered_worktree_path_state() {
  local target="$1"
  local path=""

  while IFS= read -r path; do
    [[ "$path" == "$target" ]] || continue
    if [[ -e "$target" ]]; then
      printf 'present\n'
    else
      printf 'stale\n'
    fi
    return 0
  done < <(git worktree list --porcelain 2>/dev/null | awk '$1 == "worktree" { print substr($0, 10) }')

  printf 'none\n'
}

find_slug_collision() {
  local repo="$1"
  local target_branch="$2"
  local target_slug="$3"
  local name=""
  local short_ref=""
  local branch_name=""
  local seen_branch_names=""

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$name" == "$target_branch" ]] && continue
    if [[ -n "$seen_branch_names" ]] && grep -Fqx -- "$name" <<<"$seen_branch_names"; then
      continue
    fi
    seen_branch_names+="$name"$'\n'
    [[ "$(git_worktree_slugify_branch "$name")" == "$target_slug" ]] || continue
    printf '%s\n' "$name"
    return 0
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads)

  while IFS= read -r short_ref; do
    [[ -n "$short_ref" ]] || continue
    [[ "$short_ref" == */HEAD ]] && continue
    branch_name="${short_ref#*/}"
    [[ -n "$branch_name" ]] || continue
    [[ "$branch_name" == "$target_branch" ]] && continue
    if [[ -n "$seen_branch_names" ]] && grep -Fqx -- "$branch_name" <<<"$seen_branch_names"; then
      continue
    fi
    seen_branch_names+="$branch_name"$'\n'
    [[ "$(git_worktree_slugify_branch "$branch_name")" == "$target_slug" ]] || continue
    printf '%s\n' "$branch_name"
    return 0
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/remotes)

  return 1
}

set_branch_tracking_config() {
  local repo="$1"
  local branch_name="$2"
  local remote_name="$3"
  local merge_branch_name="$4"

  git -C "$repo" config "branch.$branch_name.remote" "$remote_name"
  git -C "$repo" config "branch.$branch_name.merge" "refs/heads/$merge_branch_name"
}

discover_branch_upstream() {
  local repo="$1"
  local branch_name="$2"
  local tracked_remote=""
  local tracked_merge=""
  local remote_status=0

  DISCOVERED_BRANCH_REMOTE=""
  DISCOVERED_BRANCH_MERGE=""
  DISCOVERED_BRANCH_TRACKING_NEEDS_SET=0

  tracked_remote="$(git -C "$repo" config --get "branch.$branch_name.remote" 2>/dev/null || true)"
  tracked_merge="$(git -C "$repo" config --get "branch.$branch_name.merge" 2>/dev/null || true)"

  if [[ -n "$tracked_remote" && "$tracked_merge" == refs/heads/* ]]; then
    if [[ "$tracked_remote" == "." ]]; then
      return 0
    fi

    if remote_exists "$repo" "$tracked_remote"; then
      DISCOVERED_BRANCH_REMOTE="$tracked_remote"
      DISCOVERED_BRANCH_MERGE="${tracked_merge#refs/heads/}"
      return 0
    fi
  fi

  resolve_remote_branch_if_unique "$repo" "$branch_name" "$branch_name" || remote_status=$?
  if (( remote_status == 0 )); then
    DISCOVERED_BRANCH_REMOTE="$resolved_remote_name"
    DISCOVERED_BRANCH_MERGE="$resolved_remote_branch"
    DISCOVERED_BRANCH_TRACKING_NEEDS_SET=1
  fi
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -eq 1 ]] || {
  usage >&2
  exit 2
}

branch="$1"

if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  die "invalid branch name: $branch"
fi

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  die "not inside a git repository"
fi
repo_root="$(git_worktree_abs_dir "$repo_root")"

if ! current_branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
  die "detached HEAD is not supported"
fi

if git_worktree_is_separate_git_dir_linked_worktree "$repo_root"; then
  if ! git_worktree_authoritative_main_checkout_root "$repo_root" >/dev/null 2>&1; then
    die "cannot resolve the main checkout for this separate-git-dir repo from $(git_worktree_display_path "$repo_root"); run gwt from the main checkout or update $GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY"
  fi
fi

if git_worktree_has_legacy_container_parent "$repo_root"; then
  die "legacy repo-local container layouts are no longer supported; run gwt from a non-legacy checkout instead of $(git_worktree_display_path "$repo_root")"
fi

project_name="$(git_worktree_project_name "$repo_root")"
persist_project_name_if_authoritative "$repo_root" "$project_name"
worktrees_root="$(git_worktree_root_abs)"
project_dir="$worktrees_root/$project_name"
destination_path="$(git_worktree_target_path "$repo_root" "$branch")"
branch_slug="$(git_worktree_slugify_branch "$branch")"

if git_worktree_is_direct_repo_path "$repo_root"; then
  die "cannot create nested worktrees from direct repo at $(git_worktree_display_path "$repo_root"); run gwt from a checkout outside $(git_worktree_display_path "$project_dir")"
fi

if [[ "$current_branch" == "$branch" ]]; then
  die "branch '$branch' is already active at $(git_worktree_display_path "$repo_root")"
fi

slug_collision_branch="$(find_slug_collision "$repo_root" "$branch" "$branch_slug" || true)"
if [[ -n "$slug_collision_branch" ]]; then
  die "branch slug collision: '$branch' and '$slug_collision_branch' both map to '$branch_slug'"
fi

existing_branch_path="$(branch_worktree_path "$repo_root" "$branch" || true)"
if [[ -n "$existing_branch_path" ]]; then
  if [[ -e "$existing_branch_path" ]]; then
    echo "$script_name: branch '$branch' is already checked out at $(git_worktree_display_path "$existing_branch_path")" >&2
    if is_main_worktree_path "$repo_root" "$existing_branch_path"; then
      echo "$script_name: switch that checkout to another branch before creating a centralized worktree for '$branch'" >&2
    else
      echo "Run: git worktree remove $(shell_escape_path "$existing_branch_path")" >&2
    fi
  else
    echo "$script_name: branch '$branch' has a stale worktree entry at $(git_worktree_display_path "$existing_branch_path")" >&2
    echo "Run: git worktree prune" >&2
  fi
  exit 1
fi

destination_state="$(registered_worktree_path_state "$destination_path")"
case "$destination_state" in
  present)
    echo "$script_name: destination already exists at $(git_worktree_display_path "$destination_path")" >&2
    echo "Run: git worktree remove $(shell_escape_path "$destination_path")" >&2
    exit 1
    ;;
  stale)
    echo "$script_name: destination has a stale worktree entry at $(git_worktree_display_path "$destination_path")" >&2
    echo "Run: git worktree prune" >&2
    exit 1
    ;;
esac

if [[ -e "$destination_path" ]]; then
  echo "$script_name: destination already exists at $(git_worktree_display_path "$destination_path")" >&2
  if is_git_repository_root "$destination_path"; then
    echo "$script_name: destination is occupied by another git repo; remove or rename it manually if that is intentional" >&2
  else
    echo "Run: rm -rf $(shell_escape_path "$destination_path")" >&2
  fi
  exit 1
fi

mkdir -p "$worktrees_root"
if is_git_repository_root "$project_dir"; then
  die "cannot create nested worktrees because $(git_worktree_display_path "$project_dir") is itself a git repo"
fi
mkdir -p "$project_dir"

if local_branch_exists "$repo_root" "$branch"; then
  discover_branch_upstream "$repo_root" "$branch"
  if [[ -n "${DISCOVERED_BRANCH_REMOTE:-}" && -n "${DISCOVERED_BRANCH_MERGE:-}" ]]; then
    fetch_refspec_status=0
    ensure_remote_fetch_refspec "$repo_root" "$DISCOVERED_BRANCH_REMOTE" "$DISCOVERED_BRANCH_MERGE" || fetch_refspec_status=$?
    (( fetch_refspec_status == 0 || fetch_refspec_status == 10 )) || exit "$fetch_refspec_status"
    if (( ${DISCOVERED_BRANCH_TRACKING_NEEDS_SET:-0} )); then
      set_branch_tracking_config "$repo_root" "$branch" "$DISCOVERED_BRANCH_REMOTE" "$DISCOVERED_BRANCH_MERGE"
    fi
  fi
  git worktree add -- "$destination_path" "$branch" >/dev/null
  printf '%s\n' "$(git_worktree_display_path "$destination_path")"
  exit 0
fi

remote_status=0
resolve_remote_branch_if_unique "$repo_root" "$current_branch" "$branch" || remote_status=$?

if (( remote_status == 0 )); then
  remote_name="$resolved_remote_name"
  remote_branch="$resolved_remote_branch"
  fetch_refspec_status=0

  ensure_remote_fetch_refspec "$repo_root" "$remote_name" "$remote_branch" || fetch_refspec_status=$?
  (( fetch_refspec_status == 0 || fetch_refspec_status == 10 )) || exit "$fetch_refspec_status"

  git worktree add -b "$branch" -- "$destination_path" "refs/remotes/$remote_name/$remote_branch" >/dev/null
  set_branch_tracking_config "$repo_root" "$branch" "$remote_name" "$remote_branch"
  printf '%s\n' "$(git_worktree_display_path "$destination_path")"
  exit 0
fi

if (( remote_status == 2 )); then
  die "branch '$branch' exists on multiple remotes; create the local branch manually first"
fi

if (( remote_status == 3 )); then
  die "failed to query remotes for branch '$branch'; check network access and remote auth before retrying"
fi

git worktree add -b "$branch" -- "$destination_path" "$current_branch" >/dev/null
printf '%s\n' "$(git_worktree_display_path "$destination_path")"
