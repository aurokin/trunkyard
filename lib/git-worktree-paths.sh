#!/usr/bin/env bash

readonly GIT_WORKTREE_LEGACY_CONTAINER_MARKER=".git-worktree-container"
readonly GIT_WORKTREE_PROJECT_CONFIG_KEY="dotfiles.worktreeProjectName"
readonly GIT_WORKTREE_MAIN_CHECKOUT_PATH_CONFIG_KEY="dotfiles.worktreeMainCheckoutPath"
readonly GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY="dotfiles.worktreeMainCheckoutSearchRoot"

git_worktree_abs_dir() {
  (
    cd "$1" 2>/dev/null || return 1
    pwd -P
  )
}

git_worktree_root_path() {
  printf '%s/worktrees\n' "$(git_worktree_home_abs)"
}

git_worktree_home_abs() {
  if [[ -d "$HOME" ]]; then
    git_worktree_abs_dir "$HOME"
    return 0
  fi

  printf '%s\n' "$HOME"
}

git_worktree_root_abs() {
  local root
  root="$(git_worktree_root_path)"

  if [[ -d "$root" ]]; then
    git_worktree_abs_dir "$root"
    return 0
  fi

  printf '%s\n' "$root"
}

git_worktree_slugify_branch() {
  local value="$1"

  value="${value//\//^}"
  printf '%s\n' "$value"
}

git_worktree_display_path() {
  local path="$1"
  local home_abs=""

  home_abs="$(git_worktree_home_abs)"

  if [[ "$path" == "$HOME" || "$path" == "$home_abs" ]]; then
    printf '~\n'
    return 0
  fi

  if [[ "$path" == "$HOME/"* ]]; then
    printf '~/%s\n' "${path#"$HOME"/}"
    return 0
  fi

  if [[ "$path" == "$home_abs/"* ]]; then
    printf '~/%s\n' "${path#"$home_abs"/}"
    return 0
  fi

  printf '%s\n' "$path"
}

git_worktree_common_dir_abs() {
  local repo="$1"
  local common=""
  local common_abs=""

  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "$common" ]] || return 1

  if [[ "$common" == /* ]]; then
    common_abs="$(git_worktree_abs_dir "$common" 2>/dev/null || true)"
  else
    common_abs="$(git_worktree_abs_dir "$repo/$common" 2>/dev/null || true)"
  fi

  [[ -n "$common_abs" ]] || return 1
  printf '%s\n' "$common_abs"
}

git_worktree_git_dir_show_toplevel_abs() {
  local git_dir="$1"
  local top_level=""
  local top_level_abs=""

  top_level="$(git --git-dir="$git_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top_level" ]] || return 1

  top_level_abs="$(git_worktree_abs_dir "$top_level" 2>/dev/null || true)"
  [[ -n "$top_level_abs" ]] || return 1
  printf '%s\n' "$top_level_abs"
}

git_worktree_git_dir_abs() {
  local repo="$1"
  local git_dir=""
  local git_dir_abs=""

  git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || return 1

  git_dir_abs="$(git_worktree_abs_dir "$git_dir" 2>/dev/null || true)"
  [[ -n "$git_dir_abs" ]] || return 1
  printf '%s\n' "$git_dir_abs"
}

git_worktree_is_main_checkout() {
  local repo="$1"
  local git_dir_abs=""
  local common_abs=""

  git_dir_abs="$(git_worktree_git_dir_abs "$repo" 2>/dev/null || true)"
  common_abs="$(git_worktree_common_dir_abs "$repo" 2>/dev/null || true)"

  [[ -n "$git_dir_abs" && -n "$common_abs" && "$git_dir_abs" == "$common_abs" ]]
}

git_worktree_gitfile_target_abs() {
  local repo="$1"
  local gitfile="$repo/.git"
  local target=""

  [[ -f "$gitfile" ]] || return 1
  IFS= read -r target <"$gitfile" || return 1
  [[ "$target" == gitdir:\ * ]] || return 1
  target="${target#gitdir: }"

  if [[ "$target" == /* ]]; then
    git_worktree_abs_dir "$target" 2>/dev/null || return 1
    return 0
  fi

  git_worktree_abs_dir "$(dirname "$gitfile")/$target" 2>/dev/null || return 1
}

git_worktree_find_sibling_main_checkout() {
  local repo="$1"
  local common_abs="$2"
  local parent=""
  local candidate=""
  local gitfile_target=""

  parent="$(dirname "$repo")"
  for candidate in "$parent"/*; do
    [[ -d "$candidate" ]] || continue
    [[ "$candidate" != "$repo" ]] || continue
    gitfile_target="$(git_worktree_gitfile_target_abs "$candidate" 2>/dev/null || true)"
    [[ -n "$gitfile_target" ]] || continue
    [[ "$gitfile_target" == "$common_abs" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

git_worktree_main_checkout_root() {
  local repo="$1"
  local common_abs=""
  local common_base=""
  local git_dir_abs=""
  local sibling_main=""

  common_abs="$(git_worktree_common_dir_abs "$repo" 2>/dev/null || true)"
  [[ -n "$common_abs" ]] || return 1

  common_base="$(basename "$common_abs")"
  if [[ "$common_base" == ".git" ]]; then
    printf '%s\n' "$(dirname "$common_abs")"
    return 0
  fi

  if [[ "$common_base" == *.git ]]; then
    git_dir_abs="$(git_worktree_git_dir_abs "$repo" 2>/dev/null || true)"
    if [[ -n "$git_dir_abs" && "$git_dir_abs" == "$common_abs" ]]; then
      git_worktree_git_dir_show_toplevel_abs "$common_abs" 2>/dev/null || printf '%s\n' "$repo"
      return 0
    fi

    sibling_main="$(git_worktree_find_sibling_main_checkout "$repo" "$common_abs" 2>/dev/null || true)"
    if [[ -n "$sibling_main" ]]; then
      printf '%s\n' "$sibling_main"
      return 0
    fi

    printf '%s\n' "$repo"
    return 0
  fi

  printf '%s\n' "$repo"
}

git_worktree_relative_to_root() {
  local repo="$1"
  local root_abs
  root_abs="$(git_worktree_root_abs)"

  if [[ "$repo" == "$root_abs" ]]; then
    printf '.\n'
    return 0
  fi

  if [[ "$repo" == "$root_abs/"* ]]; then
    printf '%s\n' "${repo#"$root_abs"/}"
    return 0
  fi

  return 1
}

git_worktree_configured_project_name() {
  local repo="$1"
  git -C "$repo" config --get "$GIT_WORKTREE_PROJECT_CONFIG_KEY" 2>/dev/null || true
}

git_worktree_configured_main_checkout_path() {
  local repo="$1"
  git -C "$repo" config --get "$GIT_WORKTREE_MAIN_CHECKOUT_PATH_CONFIG_KEY" 2>/dev/null || true
}

git_worktree_configured_main_checkout_search_roots() {
  local repo="$1"
  git -C "$repo" config --get-all "$GIT_WORKTREE_MAIN_CHECKOUT_SEARCH_ROOT_CONFIG_KEY" 2>/dev/null || true
}

git_worktree_is_checkout_for_common_dir() {
  local candidate="$1"
  local common_abs="$2"
  local candidate_git_dir=""
  local candidate_gitfile_target=""

  candidate_git_dir="$(git_worktree_abs_dir "$candidate/.git" 2>/dev/null || true)"
  [[ -n "$candidate_git_dir" && "$candidate_git_dir" == "$common_abs" ]] && return 0

  candidate_gitfile_target="$(git_worktree_gitfile_target_abs "$candidate" 2>/dev/null || true)"
  [[ -n "$candidate_gitfile_target" && "$candidate_gitfile_target" == "$common_abs" ]]
}

git_worktree_collect_search_roots() {
  local repo="$1"
  local common_abs="$2"
  local configured_main="$3"
  local roots=""
  local root=""
  local root_abs=""
  local parent=""

  add_root() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 0
    root_abs="$(git_worktree_abs_dir "$candidate" 2>/dev/null || true)"
    [[ -n "$root_abs" ]] || return 0
    if [[ -n "$roots" ]] && grep -Fqx -- "$root_abs" <<<"$roots"; then
      return 0
    fi
    roots+="$root_abs"$'\n'
  }

  if [[ -n "$configured_main" ]]; then
    add_root "$(dirname "$configured_main")"
    parent="$(dirname "$(dirname "$configured_main")")"
    [[ "$parent" != "$(dirname "$configured_main")" ]] && add_root "$parent"
  fi

  add_root "$(dirname "$common_abs")"
  parent="$(dirname "$(dirname "$common_abs")")"
  [[ "$parent" != "$(dirname "$common_abs")" ]] && add_root "$parent"

  add_root "$(dirname "$repo")"
  parent="$(dirname "$(dirname "$repo")")"
  [[ "$parent" != "$(dirname "$repo")" ]] && add_root "$parent"

  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    add_root "$root"
  done < <(git_worktree_configured_main_checkout_search_roots "$repo")

  printf '%s' "$roots"
}

git_worktree_find_main_checkout_under_root() {
  local root="$1"
  local common_abs="$2"
  local candidate=""
  local resolved=""

  [[ -d "$root" ]] || return 1

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    git_worktree_is_checkout_for_common_dir "$candidate" "$common_abs" || continue
    resolved="$(git_worktree_abs_dir "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue
    printf '%s\n' "$resolved"
    return 0
  # Intentional: keep moved-main recovery bounded to a few likely levels under configured roots rather than recursively scanning large trees.
  done < <(find "$root" -maxdepth 3 -type d -print 2>/dev/null)

  return 1
}

git_worktree_resolve_configured_main_checkout_path() {
  local repo="$1"
  local common_abs="$2"
  local configured_main=""
  local configured_main_abs=""
  local search_root=""

  configured_main="$(git_worktree_configured_main_checkout_path "$repo")"

  if [[ -n "$configured_main" ]]; then
    configured_main_abs="$(git_worktree_abs_dir "$configured_main" 2>/dev/null || true)"
    if [[ -n "$configured_main_abs" ]] && git_worktree_is_checkout_for_common_dir "$configured_main_abs" "$common_abs"; then
      printf '%s\n' "$configured_main_abs"
      return 0
    fi
  fi

  while IFS= read -r search_root; do
    [[ -n "$search_root" ]] || continue
    git_worktree_find_main_checkout_under_root "$search_root" "$common_abs" 2>/dev/null && return 0
  done < <(git_worktree_collect_search_roots "$repo" "$common_abs" "$configured_main")

  return 1
}

git_worktree_authoritative_main_checkout_root() {
  local repo="$1"
  local common_abs=""
  local main_root=""
  local configured_main=""

  common_abs="$(git_worktree_common_dir_abs "$repo" 2>/dev/null || true)"
  [[ -n "$common_abs" ]] || return 1

  main_root="$(git_worktree_main_checkout_root "$repo" 2>/dev/null || true)"
  if [[ -n "$main_root" && "$main_root" != "$repo" ]]; then
    printf '%s\n' "$main_root"
    return 0
  fi

  configured_main="$(git_worktree_resolve_configured_main_checkout_path "$repo" "$common_abs" 2>/dev/null || true)"
  if [[ -n "$configured_main" ]]; then
    printf '%s\n' "$configured_main"
    return 0
  fi

  if git_worktree_is_main_checkout "$repo" && [[ -n "$main_root" ]]; then
    printf '%s\n' "$main_root"
    return 0
  fi

  return 1
}

git_worktree_is_separate_git_dir_linked_worktree() {
  local repo="$1"
  local common_abs=""
  local common_base=""

  common_abs="$(git_worktree_common_dir_abs "$repo" 2>/dev/null || true)"
  [[ -n "$common_abs" ]] || return 1
  common_base="$(basename "$common_abs")"
  [[ "$common_base" == *.git ]] || return 1
  git_worktree_is_main_checkout "$repo" && return 1
  return 0
}

git_worktree_is_direct_repo_path() {
  local repo="$1"
  local rel=""

  rel="$(git_worktree_relative_to_root "$repo" 2>/dev/null || true)"
  [[ -n "$rel" ]] || return 1
  [[ "$rel" != "." && "$rel" != */* ]]
}

git_worktree_is_nested_repo_path() {
  local repo="$1"
  local rel=""

  rel="$(git_worktree_relative_to_root "$repo" 2>/dev/null || true)"
  [[ -n "$rel" ]] || return 1
  [[ "$rel" == */* && "$rel" != */*/* ]]
}

git_worktree_has_legacy_container_parent() {
  local repo="$1"
  local repo_abs=""
  local parent=""
  local root_abs=""

  repo_abs="$(git_worktree_abs_dir "$repo" 2>/dev/null || true)"
  [[ -n "$repo_abs" ]] || return 1

  root_abs="$(git_worktree_root_abs)"
  [[ "$repo_abs" != "$root_abs" && "$repo_abs" != "$root_abs/"* ]] || return 1

  parent="$(dirname "$repo_abs")"
  [[ -f "$parent/$GIT_WORKTREE_LEGACY_CONTAINER_MARKER" ]]
}

git_worktree_project_name() {
  local repo="$1"
  local rel=""
  local configured=""
  local main_root=""
  local rel_project=""
  local authoritative_project=""

  main_root="$(git_worktree_authoritative_main_checkout_root "$repo" 2>/dev/null || true)"
  if [[ -n "$main_root" ]]; then
    authoritative_project="$(basename "$main_root")"
  fi

  rel="$(git_worktree_relative_to_root "$repo" 2>/dev/null || true)"
  if [[ -n "$rel" && "$rel" != "." ]]; then
    rel_project="${rel%%/*}"
    if [[ -n "$authoritative_project" && "$authoritative_project" != "$rel_project" ]]; then
      printf '%s\n' "$authoritative_project"
      return 0
    fi
    printf '%s\n' "$rel_project"
    return 0
  fi

  if [[ -n "$authoritative_project" ]]; then
    printf '%s\n' "$authoritative_project"
    return 0
  fi

  configured="$(git_worktree_configured_project_name "$repo")"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi

  # Intentional: centralized worktrees key project dirs by repo basename, so same-name repos share a namespace and collide by path.
  printf '%s\n' "$(basename "$repo")"
}

git_worktree_target_path() {
  local repo="$1"
  local branch="$2"
  local project=""
  local branch_slug=""
  local root_abs=""

  project="$(git_worktree_project_name "$repo")"
  branch_slug="$(git_worktree_slugify_branch "$branch")"
  root_abs="$(git_worktree_root_abs)"

  printf '%s/%s/%s\n' "$root_abs" "$project" "$branch_slug"
}
