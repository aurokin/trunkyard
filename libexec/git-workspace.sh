#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_name="${TRUNKYARD_CMD:-$(basename "$0")}"
readonly STATUS_ROW_SEP=$'\x1f'
script_dir="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null
  pwd -P
)"

# shellcheck source=/dev/null
source "$script_dir/../lib/git-worktree-paths.sh"

# Return codes (used for pull job summarization).
readonly RC_OK=0
readonly RC_FAIL=2
readonly RC_FAIL_ARGS=3
readonly RC_SKIP_DETACHED=10
readonly RC_SKIP_DIRTY=11
readonly RC_SKIP_NO_REMOTE=12
readonly RC_SKIP_UP_TO_DATE=13

# Parallel worker pool state.
POOL_JOBS=1
POOL_SUPPORTS_N=0
POOL_RUNNING=0
POOL_PIDS=()

HAVE_FLOCK=0
if command -v flock >/dev/null 2>&1; then
  HAVE_FLOCK=1
fi

WARNED_NO_FLOCK=0
warn_no_flock_parallel() {
  ((HAVE_FLOCK)) && return 0
  ((WARNED_NO_FLOCK)) && return 0
  echo "$script_name: WARN: 'flock' not found; running without repo locks (install util-linux to enable locking)" >&2
  WARNED_NO_FLOCK=1
}

# Temp directories to clean up on exit.
CLEANUP_DIRS=()

cleanup() {
  set +e
  set +u
  local d
  for d in "${CLEANUP_DIRS[@]}"; do
    [[ -n "$d" ]] || continue
    rm -rf "$d" >/dev/null 2>&1 || true
  done
}

trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  $script_name status [path] [--no-fetch] [--jobs N]
  $script_name pull [path] [--include-dirty] [--no-ff-only] [--no-fetch] [--jobs N] [--ttl N] [--force-fetch] [--] [git pull args...]

Environment:
  GIT_WORKSPACE_JOBS  Default for --jobs (default: min(CPU, 8))
  GIT_WORKSPACE_CACHE_DIR  Cache dir (default: \$XDG_CACHE_HOME/git-workspace or ~/.cache/git-workspace)
  GIT_WORKSPACE_FETCH_TTL_SECONDS  Treat remote as fresh for N seconds after a successful fetch (default: 120)

Notes:
  - If available, uses "flock" (util-linux) to lock git operations per repo
    (helps avoid ref lock races when scanning multiple worktrees in parallel).

Scans:
  - <path> (default: .)
  - outside ~/worktrees: the path itself plus each immediate subdirectory
  - at ~/worktrees exactly: direct repos at ~/worktrees/<project> and nested repos
    at ~/worktrees/<project>/<branch>

Status report includes:
  - ahead/behind vs upstream (or origin/<branch> fallback)
  - working tree counts: w (unstaged), s (staged), u (untracked), c (conflicts)

Examples:
  $script_name status
  $script_name status ~/code --no-fetch
  $script_name status ~/code --jobs 8
  $script_name pull ~/code
  $script_name pull --include-dirty -- --rebase
  $script_name pull --no-fetch   # fast (assumes you've already fetched, e.g. via status)
  $script_name pull --ttl 0      # disable fetch cache shortcut
EOF
}

die() {
  echo "$script_name: $*" >&2
  exit 1
}

abs_dir() {
  git_worktree_abs_dir "$1"
}

relpath() {
  local base_abs="$1"
  local target_abs="$2"
  if [[ "$target_abs" == "$base_abs" ]]; then
    printf '%s' '.'
  elif [[ "$target_abs" == "$base_abs/"* ]]; then
    printf '%s' "${target_abs#"$base_abs"/}"
  else
    printf '%s' "$target_abs"
  fi
}

is_git_repo_root() {
  local path="$1"
  local path_abs=""
  local top_level=""
  local git_dir=""

  path_abs="$(abs_dir "$path" 2>/dev/null || true)"
  [[ -n "$path_abs" ]] || return 1

  top_level="$(git -C "$path_abs" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$top_level" ]]; then
    [[ "$(abs_dir "$top_level" 2>/dev/null || true)" == "$path_abs" ]] && return 0
  fi

  git_dir="$(git -C "$path_abs" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" && "$(abs_dir "$git_dir" 2>/dev/null || true)" == "$path_abs" ]]
}

is_bare_repo_root() {
  local path="$1"
  local path_abs=""
  local git_dir=""

  path_abs="$(abs_dir "$path" 2>/dev/null || true)"
  [[ -n "$path_abs" ]] || return 1

  git_dir="$(git -C "$path_abs" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || return 1
  [[ "$(abs_dir "$git_dir" 2>/dev/null || true)" == "$path_abs" ]] || return 1
  git -C "$path_abs" rev-parse --is-bare-repository 2>/dev/null | grep -qx true
}

git_remote_exists() {
  local repo="$1"
  local remote="$2"
  git -C "$repo" remote get-url "$remote" >/dev/null 2>&1
}

split_upstream_ref() {
  local repo="$1"
  local upstream="$2"
  local candidate_remote=""

  SPLIT_UPSTREAM_REMOTE=""
  SPLIT_UPSTREAM_BRANCH=""
  [[ -n "$upstream" ]] || return 1

  while IFS= read -r candidate_remote; do
    [[ -n "$candidate_remote" ]] || continue
    if [[ "$upstream" == "$candidate_remote/"* ]]; then
      SPLIT_UPSTREAM_REMOTE="$candidate_remote"
      SPLIT_UPSTREAM_BRANCH="${upstream#"$candidate_remote"/}"
      [[ -n "$SPLIT_UPSTREAM_BRANCH" ]] || return 1
      return 0
    fi
  done < <(git -C "$repo" remote)

  return 1
}

resolve_branch_tracking_target() {
  local repo="$1"
  local branch_head="$2"
  local tracked_remote=""
  local tracked_merge=""

  TRACKING_TARGET_KIND=""
  TRACKING_TARGET_REMOTE=""
  TRACKING_TARGET_BRANCH=""

  [[ -n "$branch_head" && "$branch_head" != "(detached)" ]] || return 1

  tracked_remote="$(git -C "$repo" config --get "branch.$branch_head.remote" 2>/dev/null || true)"
  tracked_merge="$(git -C "$repo" config --get "branch.$branch_head.merge" 2>/dev/null || true)"
  [[ -n "$tracked_remote" && "$tracked_merge" == refs/heads/* ]] || return 1

  TRACKING_TARGET_BRANCH="${tracked_merge#refs/heads/}"
  [[ -n "$TRACKING_TARGET_BRANCH" ]] || return 1

  if [[ "$tracked_remote" == "." ]]; then
    TRACKING_TARGET_KIND="local"
    return 0
  fi

  if git_remote_exists "$repo" "$tracked_remote"; then
    TRACKING_TARGET_KIND="remote"
    TRACKING_TARGET_REMOTE="$tracked_remote"
    return 0
  fi

  TRACKING_TARGET_BRANCH=""
  return 1
}

# Globals filled by collect_porcelain()
POR_BRANCH_HEAD=""
POR_BRANCH_OID=""
POR_UPSTREAM=""
POR_AB_AHEAD=""
POR_AB_BEHIND=""
POR_STAGED=0
POR_UNSTAGED=0
POR_UNTRACKED=0
POR_CONFLICTS=0

collect_porcelain() {
  local repo="$1"
  local out
  out="$(git -C "$repo" status --porcelain=2 -b 2>/dev/null)" || return 1

  local branch_head=""
  local branch_oid=""
  local upstream=""
  local ab_ahead=""
  local ab_behind=""
  local staged=0
  local unstaged=0
  local untracked=0
  local conflicts=0

  local ab=""
  local xy=""
  local x=""
  local y=""
  local line=""
  while IFS= read -r line; do
    case "$line" in
      "# branch.head "*)
        branch_head="${line#"# branch.head "}"
        ;;
      "# branch.oid "*)
        branch_oid="${line#"# branch.oid "}"
        ;;
      "# branch.upstream "*)
        upstream="${line#"# branch.upstream "}"
        ;;
      "# branch.ab "*)
        # Example: "# branch.ab +2 -10" (ahead, behind)
        ab="${line#"# branch.ab "}"
        ab_ahead="${ab%% *}"
        ab_behind="${ab#* }"
        ab_ahead="${ab_ahead#+}"
        ab_behind="${ab_behind#-}"
        ;;
      "? "*)
        ((++untracked))
        ;;
      "u "*)
        ((++conflicts))
        ;;
      "1 "*|"2 "*)
        xy="${line:2:2}"
        x="${xy:0:1}"
        y="${xy:1:1}"
        [[ "$x" != "." ]] && ((++staged))
        [[ "$y" != "." ]] && ((++unstaged))
        ;;
      *)
        :
        ;;
    esac
  done <<<"$out"

  POR_BRANCH_HEAD="$branch_head"
  POR_BRANCH_OID="$branch_oid"
  POR_UPSTREAM="$upstream"
  POR_AB_AHEAD="$ab_ahead"
  POR_AB_BEHIND="$ab_behind"
  POR_STAGED="$staged"
  POR_UNSTAGED="$unstaged"
  POR_UNTRACKED="$untracked"
  POR_CONFLICTS="$conflicts"
}

compare_ref_for_repo() {
  local repo="$1"
  local branch_head="$2"
  local upstream="$3"

  if resolve_branch_tracking_target "$repo" "$branch_head"; then
    if [[ "$TRACKING_TARGET_KIND" == "local" ]]; then
      printf '%s' "$TRACKING_TARGET_BRANCH"
    else
      printf '%s/%s' "$TRACKING_TARGET_REMOTE" "$TRACKING_TARGET_BRANCH"
    fi
    return 0
  fi

  if [[ -n "$upstream" ]]; then
    printf '%s' "$upstream"
    return 0
  fi

  if [[ -z "$branch_head" || "$branch_head" == "(detached)" ]]; then
    return 1
  fi

  if ! git_remote_exists "$repo" origin; then
    return 1
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch_head" 2>/dev/null; then
    printf '%s' "origin/$branch_head"
    return 0
  fi

  return 1
}

mktemp_dir() {
  local d
  d="$(mktemp -d 2>/dev/null)" && { printf '%s' "$d"; return 0; }
  d="$(mktemp -d -t git-workspace 2>/dev/null)" && { printf '%s' "$d"; return 0; }
  return 1
}

cache_root() {
  if [[ -n "${GIT_WORKSPACE_CACHE_DIR:-}" ]]; then
    printf '%s' "$GIT_WORKSPACE_CACHE_DIR"
    return 0
  fi
  local root="${XDG_CACHE_HOME:-$HOME/.cache}"
  printf '%s' "$root/git-workspace"
}

cache_key() {
  local s="$1"
  local out=""
  if command -v sha1sum >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | sha1sum 2>/dev/null || true)"
    printf '%s' "${out%% *}"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | shasum -a 1 2>/dev/null || true)"
    printf '%s' "${out%% *}"
    return 0
  fi
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | md5sum 2>/dev/null || true)"
    printf '%s' "${out%% *}"
    return 0
  fi

  # Fallback: checksum + length.
  out="$(printf '%s' "$s" | cksum 2>/dev/null || true)"
  local crc="${out%% *}"
  local rest="${out#* }"
  local len="${rest%% *}"
  printf '%s_%s' "$crc" "$len"
}

cache_fetch_file() {
  local repo_abs="$1"
  local dir
  dir="$(cache_root)"
  printf '%s/fetch-%s.ts' "$dir" "$(cache_key "$repo_abs")"
}

cache_write_fetch_time() {
  local repo_abs="$1"
  local dir
  dir="$(cache_root)"
  mkdir -p "$dir" 2>/dev/null || return 1
  date +%s >"$(cache_fetch_file "$repo_abs")" 2>/dev/null || return 1
}

cache_read_fetch_time() {
  local repo_abs="$1"
  local f
  f="$(cache_fetch_file "$repo_abs")"
  [[ -f "$f" ]] || return 1
  local ts
  ts="$(<"$f")"
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$ts"
}

cache_is_fresh() {
  local repo_abs="$1"
  local ttl="$2"
  [[ "$ttl" =~ ^[0-9]+$ ]] || return 1
  ((ttl > 0)) || return 1

  local last
  last="$(cache_read_fetch_time "$repo_abs" 2>/dev/null || true)"
  [[ -n "$last" ]] || return 1

  local now
  now="$(date +%s 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1

  local age=$((now - last))
  if ((age < 0)); then
    return 0
  fi
  ((age <= ttl))
}

repo_lockfile() {
  local repo="$1"
  local key_source="$repo"

  local common=""
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" ]]; then
    if [[ "$common" == /* ]]; then
      key_source="$common"
    else
      local common_abs=""
      common_abs="$(abs_dir "$repo/$common" 2>/dev/null || true)"
      [[ -n "$common_abs" ]] && key_source="$common_abs"
    fi
  fi

  local root
  root="$(cache_root)"
  printf '%s/locks/%s.lock' "$root" "$(cache_key "$key_source")"
}

lock_run() {
  local repo="$1"
  shift

  if ((HAVE_FLOCK == 0)); then
    "$@"
    return $?
  fi

  local lockfile
  lockfile="$(repo_lockfile "$repo")"
  local lockdir="${lockfile%/*}"
  mkdir -p "$lockdir" 2>/dev/null || true

  flock "$lockfile" "$@"
}

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null && return 0
  fi
  echo 4
}

default_jobs() {
  local from_env="${GIT_WORKSPACE_JOBS:-}"
  if [[ -n "$from_env" ]]; then
    printf '%s' "$from_env"
    return 0
  fi
  local n
  n="$(cpu_count)"
  # Cap default concurrency so we don't melt the network.
  if [[ "$n" =~ ^[0-9]+$ ]] && ((n > 8)); then
    n=8
  fi
  if [[ ! "$n" =~ ^[0-9]+$ ]] || ((n < 1)); then
    n=4
  fi
  printf '%s' "$n"
}

supports_wait_n() {
  # wait -n exists in bash >= 4.3
  local major="${BASH_VERSINFO[0]:-0}"
  local minor="${BASH_VERSINFO[1]:-0}"
  ((major > 4)) || { ((major == 4)) && ((minor >= 3)); }
}

pool_setup() {
  local jobs="$1"
  POOL_JOBS="$jobs"
  POOL_RUNNING=0
  POOL_PIDS=()
  POOL_SUPPORTS_N=0
  if supports_wait_n; then
    POOL_SUPPORTS_N=1
  fi
}

pool_throttle() {
  local pid="${1:-}"

  if ((POOL_SUPPORTS_N)); then
    ((++POOL_RUNNING))
    if ((POOL_RUNNING >= POOL_JOBS)); then
      wait -n || true
      POOL_RUNNING=$((POOL_RUNNING - 1))
    fi
    return 0
  fi

  [[ -n "$pid" ]] || die "internal: pool_throttle missing pid"
  POOL_PIDS+=("$pid")
  if ((${#POOL_PIDS[@]} >= POOL_JOBS)); then
    wait "${POOL_PIDS[0]}" || true
    POOL_PIDS=("${POOL_PIDS[@]:1}")
  fi
}

pool_wait_all() {
  if ((POOL_SUPPORTS_N)); then
    while ((POOL_RUNNING > 0)); do
      wait -n || true
      POOL_RUNNING=$((POOL_RUNNING - 1))
    done
    return 0
  fi

  local pid
  for pid in "${POOL_PIDS[@]}"; do
    wait "$pid" || true
  done
}

status_row_tsv() {
  local repo="$1"
  local fetch_enabled="$2"

  if is_bare_repo_root "$repo"; then
    local display_path
    display_path="$(relpath "$BASE_ABS" "$repo")"
    printf '%s%s%s%s%s%s%s%s%s%s%d%s%d%s%d%s%d\n' \
      "$display_path" "$STATUS_ROW_SEP" \
      "" "$STATUS_ROW_SEP" \
      "" "$STATUS_ROW_SEP" \
      "bare-repo" "$STATUS_ROW_SEP" \
      "" "$STATUS_ROW_SEP" \
      0 "$STATUS_ROW_SEP" \
      0 "$STATUS_ROW_SEP" \
      0 "$STATUS_ROW_SEP" \
      0
    return 0
  fi

  if ! collect_porcelain "$repo"; then
    local display_path
    display_path="$(relpath "$BASE_ABS" "$repo")"
    printf '%s%s%s%s%s%s%s%s%s%s%d%s%d%s%d%s%d\n' \
      "$display_path" "$STATUS_ROW_SEP" \
      "" "$STATUS_ROW_SEP" \
      "" "$STATUS_ROW_SEP" \
      "status-error" "$STATUS_ROW_SEP" \
      "" "$STATUS_ROW_SEP" \
      0 "$STATUS_ROW_SEP" \
      0 "$STATUS_ROW_SEP" \
      0 "$STATUS_ROW_SEP" \
      0
    return 0
  fi

  local fetch_status=""
  local fetched=0
  if ((fetch_enabled)); then
    local fetch_remote=""
    local fetch_branch=""
    local tracking_kind=""

    # Targeted fetch: only the tracked branch.
    if resolve_branch_tracking_target "$repo" "$POR_BRANCH_HEAD"; then
      tracking_kind="$TRACKING_TARGET_KIND"
      if [[ "$tracking_kind" == "remote" ]]; then
        fetch_remote="$TRACKING_TARGET_REMOTE"
        fetch_branch="$TRACKING_TARGET_BRANCH"
      fi
    elif [[ -n "$POR_UPSTREAM" ]]; then
      if split_upstream_ref "$repo" "$POR_UPSTREAM"; then
        fetch_remote="$SPLIT_UPSTREAM_REMOTE"
        fetch_branch="$SPLIT_UPSTREAM_BRANCH"
      fi
    elif [[ -n "$POR_BRANCH_HEAD" && "$POR_BRANCH_HEAD" != "(detached)" ]] && git_remote_exists "$repo" origin; then
      fetch_remote="origin"
      fetch_branch="$POR_BRANCH_HEAD"
    fi

    if [[ -n "$fetch_remote" && -n "$fetch_branch" ]]; then
      # These defaults avoid slow recursive submodule fetches and tag downloads.
      local refspec="+refs/heads/$fetch_branch:refs/remotes/$fetch_remote/$fetch_branch"
      if ! lock_run "$repo" git -C "$repo" fetch --prune --quiet --no-tags --recurse-submodules=no "$fetch_remote" "$refspec" >/dev/null 2>&1; then
        fetch_status="fetch-error"
      else
        fetched=1
        cache_write_fetch_time "$repo" >/dev/null 2>&1 || true
      fi
    fi
  fi

  local compare_ref=""
  compare_ref="$(compare_ref_for_repo "$repo" "$POR_BRANCH_HEAD" "$POR_UPSTREAM" 2>/dev/null || true)"

  local sync=""
  local behind_flag=0
  local no_upstream_flag=0
  local fetch_error_flag=0

  if [[ -n "$fetch_status" ]]; then
    sync="$fetch_status"
    fetch_error_flag=1
  elif [[ -z "$compare_ref" ]]; then
    sync="no-upstream"
    no_upstream_flag=1
  else
    local ahead=""
    local behind=""
    local ab=""

    if ((fetched == 0)) && [[ -n "$POR_UPSTREAM" && "$compare_ref" == "$POR_UPSTREAM" && -n "$POR_AB_AHEAD" && -n "$POR_AB_BEHIND" ]]; then
      ahead="$POR_AB_AHEAD"
      behind="$POR_AB_BEHIND"
    else
      if ab="$(ahead_behind "$repo" "$compare_ref" 2>/dev/null)"; then
        ahead="${ab%%$'\t'*}"
        behind="${ab#*$'\t'}"
      else
        sync="sync-error"
      fi
    fi

    if [[ -z "$sync" ]]; then
      if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
        sync="ok"
      elif [[ "$ahead" == "0" ]]; then
        sync="behind:$behind"
        behind_flag=1
      elif [[ "$behind" == "0" ]]; then
        sync="ahead:$ahead"
      else
        sync="diverged:+$ahead -$behind"
        behind_flag=1
      fi
    fi
  fi

  local branch_display="$POR_BRANCH_HEAD"
  if [[ "$POR_BRANCH_HEAD" == "(detached)" ]]; then
    if [[ -n "$POR_BRANCH_OID" && "$POR_BRANCH_OID" != "(initial)" ]]; then
      branch_display="detached@${POR_BRANCH_OID:0:7}"
    else
      branch_display="detached"
    fi
  fi

  local dirty_total=$((POR_STAGED + POR_UNSTAGED + POR_UNTRACKED + POR_CONFLICTS))
  local dirty="clean"
  local dirty_flag=0
  if ((dirty_total > 0)); then
    dirty="w:${POR_UNSTAGED} s:${POR_STAGED} u:${POR_UNTRACKED}"
    if ((POR_CONFLICTS > 0)); then
      dirty="c:${POR_CONFLICTS} $dirty"
    fi
    dirty_flag=1
  fi

  local display_path
  display_path="$(relpath "$BASE_ABS" "$repo")"

  printf '%s%s%s%s%s%s%s%s%s%s%d%s%d%s%d%s%d\n' \
    "$display_path" "$STATUS_ROW_SEP" \
    "$branch_display" "$STATUS_ROW_SEP" \
    "$compare_ref" "$STATUS_ROW_SEP" \
    "$sync" "$STATUS_ROW_SEP" \
    "$dirty" "$STATUS_ROW_SEP" \
    "$behind_flag" "$STATUS_ROW_SEP" \
    "$dirty_flag" "$STATUS_ROW_SEP" \
    "$no_upstream_flag" "$STATUS_ROW_SEP" \
    "$fetch_error_flag"
}

pull_job() {
  local repo="$1"
  local display_path="$2"
  local include_dirty="$3"
  local ff_only="$4"
  local no_fetch="$5"
  local ttl="$6"
  local force_fetch="$7"
  shift 7
  local -a extra_pull_args=("$@")
 
  if is_bare_repo_root "$repo"; then
    echo "==> $display_path"
    echo "SKIP: bare repo"
    return $RC_SKIP_NO_REMOTE
  fi

  if ! collect_porcelain "$repo"; then
    echo "==> $display_path"
    echo "FAIL: status-error"
    return $RC_FAIL
  fi

  if [[ "$POR_BRANCH_HEAD" == "(detached)" ]]; then
    echo "==> $display_path (detached)"
    echo "SKIP: detached HEAD"
    return $RC_SKIP_DETACHED
  fi

  local dirty_total=$((POR_STAGED + POR_UNSTAGED + POR_UNTRACKED + POR_CONFLICTS))
  if ((include_dirty == 0 && dirty_total > 0)); then
    echo "==> $display_path ($POR_BRANCH_HEAD)"
    echo "SKIP: dirty (w:${POR_UNSTAGED} s:${POR_STAGED} u:${POR_UNTRACKED} c:${POR_CONFLICTS})"
    return $RC_SKIP_DIRTY
  fi

  local compare_ref=""
  compare_ref="$(compare_ref_for_repo "$repo" "$POR_BRANCH_HEAD" "$POR_UPSTREAM" 2>/dev/null || true)"

  # Cache shortcut: if we just fetched (e.g. via `status`), avoid re-fetching.
  # Only used when we can rely on local remote-tracking refs.
  if ((no_fetch == 0 && force_fetch == 0)) && cache_is_fresh "$repo" "$ttl"; then
    if [[ -n "$compare_ref" ]]; then
      local ahead=""
      local behind=""
      local ab=""
      if [[ -n "$POR_UPSTREAM" && "$compare_ref" == "$POR_UPSTREAM" && -n "$POR_AB_AHEAD" && -n "$POR_AB_BEHIND" ]]; then
        ahead="$POR_AB_AHEAD"
        behind="$POR_AB_BEHIND"
      else
        if ab="$(ahead_behind "$repo" "$compare_ref" 2>/dev/null)"; then
          ahead="${ab%%$'\t'*}"
          behind="${ab#*$'\t'}"
        fi
      fi

      if [[ "$behind" == "0" ]]; then
        echo "==> $display_path ($POR_BRANCH_HEAD)"
        echo "SKIP: up-to-date"
        return $RC_SKIP_UP_TO_DATE
      fi

      if ((ff_only == 1)) && [[ ${#extra_pull_args[@]} -eq 0 ]]; then
        echo "==> $display_path ($POR_BRANCH_HEAD)"
        lock_run "$repo" git -C "$repo" merge --ff-only "$compare_ref"
        return $?
      fi
    fi
  fi

  if ((no_fetch)); then
    # merge-only fast path (assumes compare_ref already updated by a prior fetch).
    if ((ff_only == 0)); then
      echo "==> $display_path ($POR_BRANCH_HEAD)"
      echo "FAIL: --no-fetch requires --ff-only"
      return $RC_FAIL_ARGS
    fi
    if [[ ${#extra_pull_args[@]} -gt 0 ]]; then
      echo "==> $display_path ($POR_BRANCH_HEAD)"
      echo "FAIL: --no-fetch does not accept extra git pull args"
      return $RC_FAIL_ARGS
    fi
    if [[ -z "$compare_ref" ]]; then
      echo "==> $display_path ($POR_BRANCH_HEAD)"
      echo "SKIP: no upstream (run without --no-fetch)"
      return $RC_SKIP_NO_REMOTE
    fi

    local ab=""
    local behind=""
    if [[ -n "$POR_UPSTREAM" && "$compare_ref" == "$POR_UPSTREAM" && -n "$POR_AB_BEHIND" ]]; then
      behind="$POR_AB_BEHIND"
    else
      if ab="$(ahead_behind "$repo" "$compare_ref" 2>/dev/null)"; then
        behind="${ab#*$'\t'}"
      fi
    fi
    if [[ "$behind" == "0" ]]; then
      echo "==> $display_path ($POR_BRANCH_HEAD)"
      echo "SKIP: up-to-date"
      return $RC_SKIP_UP_TO_DATE
    fi

    echo "==> $display_path ($POR_BRANCH_HEAD)"
    lock_run "$repo" git -C "$repo" merge --ff-only "$compare_ref"
    return $?
  fi

  local remote=""
  local remote_branch=""
  local upstream="$POR_UPSTREAM"
  local has_local_upstream=0
  local local_upstream_branch=""
  if resolve_branch_tracking_target "$repo" "$POR_BRANCH_HEAD"; then
    if [[ "$TRACKING_TARGET_KIND" == "local" ]]; then
      has_local_upstream=1
      local_upstream_branch="$TRACKING_TARGET_BRANCH"
    else
      remote="$TRACKING_TARGET_REMOTE"
      remote_branch="$TRACKING_TARGET_BRANCH"
    fi
  elif [[ -n "$upstream" ]]; then
    if split_upstream_ref "$repo" "$upstream"; then
      remote="$SPLIT_UPSTREAM_REMOTE"
      remote_branch="$SPLIT_UPSTREAM_BRANCH"
    else
      has_local_upstream=1
      local_upstream_branch="$upstream"
    fi
  elif git_remote_exists "$repo" origin; then
    remote="origin"
    remote_branch="$POR_BRANCH_HEAD"
  else
    echo "==> $display_path ($POR_BRANCH_HEAD)"
    echo "SKIP: no upstream and no origin remote"
    return $RC_SKIP_NO_REMOTE
  fi

  # Optimized default path: fetch quietly, then ff-only merge if needed.
  if ((ff_only == 1)) && [[ ${#extra_pull_args[@]} -eq 0 ]]; then
    if ((has_local_upstream)); then
      local ab=""
      local behind=""
      if ab="$(ahead_behind "$repo" "$compare_ref" 2>/dev/null)"; then
        behind="${ab#*$'\t'}"
      fi
      if [[ "$behind" == "0" ]]; then
        echo "==> $display_path ($POR_BRANCH_HEAD)"
        echo "SKIP: up-to-date"
        return $RC_SKIP_UP_TO_DATE
      fi

      echo "==> $display_path ($POR_BRANCH_HEAD)"
      lock_run "$repo" git -C "$repo" merge --ff-only "$compare_ref"
      return $?
    fi

    local refspec="+refs/heads/$remote_branch:refs/remotes/$remote/$remote_branch"
    if ! lock_run "$repo" git -C "$repo" fetch --prune --quiet --no-tags --recurse-submodules=no "$remote" "$refspec"; then
      echo "==> $display_path ($POR_BRANCH_HEAD)"
      echo "FAIL: fetch"
      return $RC_FAIL
    fi
    cache_write_fetch_time "$repo" >/dev/null 2>&1 || true

    compare_ref="$remote/$remote_branch"
    local ab=""
    local behind=""
    if ab="$(ahead_behind "$repo" "$compare_ref" 2>/dev/null)"; then
      behind="${ab#*$'\t'}"
    fi
    if [[ "$behind" == "0" ]]; then
      echo "==> $display_path ($POR_BRANCH_HEAD)"
      echo "SKIP: up-to-date"
      return $RC_SKIP_UP_TO_DATE
    fi

    echo "==> $display_path ($POR_BRANCH_HEAD)"
    lock_run "$repo" git -C "$repo" merge --ff-only "$compare_ref"
    return $?
  fi

  echo "==> $display_path ($POR_BRANCH_HEAD)"
  local -a pull_cmd
  pull_cmd=(git -C "$repo" pull --prune --no-tags --recurse-submodules=no)
  if ((ff_only)); then
    pull_cmd+=(--ff-only)
  fi
  if [[ ${#extra_pull_args[@]} -gt 0 ]]; then
    pull_cmd+=("${extra_pull_args[@]}")
  fi
  if ((has_local_upstream)); then
    pull_cmd+=("." "$local_upstream_branch")
  else
    pull_cmd+=("$remote" "$remote_branch")
  fi

  lock_run "$repo" "${pull_cmd[@]}"
}

ahead_behind() {
  local repo="$1"
  local compare_ref="$2"
  local out
  out="$(git -C "$repo" rev-list --left-right --count "${compare_ref}...HEAD" 2>/dev/null)" || return 1
  local behind=0
  local ahead=0
  IFS=$'\t ' read -r behind ahead <<<"$out"
  printf '%s\t%s' "$ahead" "$behind"
}

discover_repos() {
  local base="$1"
  local base_abs
  local seen_repos=""
  base_abs="$(abs_dir "$base")" || return 1

  BASE_ABS="$base_abs"
  BASE_IS_WORKTREES_ROOT=0
  REPOS=()
  DIRECT_REPOS=()
  NESTED_REPOS=()

  add_repo() {
    local dir="$1"
    local abs
    abs="$(abs_dir "$dir")" || return 0
    if [[ -n "$seen_repos" ]] && grep -Fqx -- "$abs" <<<"$seen_repos"; then
      return 0
    fi
    seen_repos+="$abs"$'\n'
    REPOS+=("$abs")
  }

  add_direct_repo() {
    local dir="$1"
    local abs
    local stored="$dir"
    abs="$(abs_dir "$dir")" || return 0
    if [[ -n "$seen_repos" ]] && grep -Fqx -- "$abs" <<<"$seen_repos"; then
      return 0
    fi
    seen_repos+="$abs"$'\n'
    DIRECT_REPOS+=("$stored")
  }

  add_nested_repo() {
    local dir="$1"
    local abs
    local stored="$dir"
    abs="$(abs_dir "$dir")" || return 0
    if [[ -n "$seen_repos" ]] && grep -Fqx -- "$abs" <<<"$seen_repos"; then
      return 0
    fi
    seen_repos+="$abs"$'\n'
    NESTED_REPOS+=("$stored")
  }

  if [[ "$base_abs" == "$(git_worktree_root_abs)" ]]; then
    BASE_IS_WORKTREES_ROOT=1
    shopt -s nullglob
    local project_dir=""
    local branch_dir=""

    for project_dir in "$base_abs"/*; do
      [[ -d "$project_dir" ]] || continue
      if is_git_repo_root "$project_dir"; then
        add_direct_repo "$project_dir"
        continue
      fi
      for branch_dir in "$project_dir"/*; do
        [[ -d "$branch_dir" ]] || continue
        is_git_repo_root "$branch_dir" || continue
        add_nested_repo "$branch_dir"
      done
    done

    # Both arrays are initialized above, so one-section ~/worktrees layouts are safe under set -u.
    REPOS=("${DIRECT_REPOS[@]}" "${NESTED_REPOS[@]}")

    return 0
  fi

  local candidates=("$base_abs")
  shopt -s nullglob
  local d=""
  for d in "$base_abs"/*; do
    [[ -d "$d" ]] || continue
    candidates+=("$d")
  done

  local c=""
  for c in "${candidates[@]}"; do
    is_git_repo_root "$c" || continue
    add_repo "$c"
  done
}

render_table_lines() {
  local lines_name="$1"
  local title="${2:-}"
  local line_count=0
  local path_w=4
  local branch_w=6
  local remote_w=6
  local sync_w=4
  local dirty_w=5
  local i=0
  local line=""
  local pth=""
  local br=""
  local rem=""
  local syn=""
  local dir=""
  local ignored=""

  eval "line_count=\${#$lines_name[@]}"
  (( line_count > 0 )) || return 0

  if [[ -n "$title" ]]; then
    echo "$title"
  fi

  for ((i = 0; i < line_count; i++)); do
    eval "line=\${$lines_name[$i]}"
    IFS="$STATUS_ROW_SEP" read -r pth br rem syn dir ignored <<<"$line"
    (( ${#pth} > path_w )) && path_w=${#pth}
    (( ${#br} > branch_w )) && branch_w=${#br}
    (( ${#rem} > remote_w )) && remote_w=${#rem}
    (( ${#syn} > sync_w )) && sync_w=${#syn}
    (( ${#dir} > dirty_w )) && dirty_w=${#dir}
  done

  printf "%-${path_w}s  %-${branch_w}s  %-${remote_w}s  %-${sync_w}s  %s\n" \
    "path" "branch" "remote" "sync" "dirty"
  printf "%-${path_w}s  %-${branch_w}s  %-${remote_w}s  %-${sync_w}s  %s\n" \
    "----" "------" "------" "----" "-----"

  for ((i = 0; i < line_count; i++)); do
    eval "line=\${$lines_name[$i]}"
    IFS="$STATUS_ROW_SEP" read -r pth br rem syn dir ignored <<<"$line"
    printf "%-${path_w}s  %-${branch_w}s  %-${remote_w}s  %-${sync_w}s  %s\n" \
      "$pth" "$br" "$rem" "$syn" "$dir"
  done
}

print_status() {
  local base="."
  local fetch_enabled=1
  local jobs
  jobs="$(default_jobs)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-fetch)
        fetch_enabled=0
        ;;
      --jobs|-j)
        shift
        [[ $# -gt 0 ]] || die "--jobs requires a number"
        jobs="$1"
        ;;
      --jobs=*)
        jobs="${1#--jobs=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        base="$1"
        ;;
    esac
    shift
  done

  [[ "$jobs" =~ ^[0-9]+$ ]] || die "--jobs must be an integer"
  ((jobs >= 1)) || die "--jobs must be >= 1"

  if ((fetch_enabled)); then
    warn_no_flock_parallel
  fi

  discover_repos "$base" || die "not a directory: $base"
  if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "No git repos found."
    return 0
  fi

  local tmp
  tmp="$(mktemp_dir)" || die "failed to create temp dir"

  CLEANUP_DIRS+=("$tmp")

  pool_setup "$jobs"

  local idx=0
  local repo=""
  for repo in "${REPOS[@]}"; do
    (
      set +e
      status_row_tsv "$repo" "$fetch_enabled" >"$tmp/$idx.tsv"
      exit 0
    ) &

    pool_throttle "$!"

    ((++idx))
  done

  pool_wait_all

  ALL_STATUS_LINES=()
  DIRECT_STATUS_LINES=()
  NESTED_STATUS_LINES=()

  local behind_repos=0
  local dirty_repos=0
  local no_upstream=0
  local fetch_errors=0
  local line=""

  for ((idx = 0; idx < ${#REPOS[@]}; idx++)); do
    if [[ ! -f "$tmp/$idx.tsv" ]]; then
      continue
    fi
    line="$(<"$tmp/$idx.tsv")"

    local pth br rem syn dir behind_flag dirty_flag no_upstream_flag fetch_error_flag
    IFS="$STATUS_ROW_SEP" read -r pth br rem syn dir behind_flag dirty_flag no_upstream_flag fetch_error_flag <<<"$line"

    ALL_STATUS_LINES+=("$line")
    if (( BASE_IS_WORKTREES_ROOT )); then
      if git_worktree_is_direct_repo_path "${REPOS[$idx]}"; then
        DIRECT_STATUS_LINES+=("$line")
      elif git_worktree_is_nested_repo_path "${REPOS[$idx]}"; then
        NESTED_STATUS_LINES+=("$line")
      fi
    fi

    [[ "${behind_flag:-0}" == "1" ]] && ((++behind_repos))
    [[ "${dirty_flag:-0}" == "1" ]] && ((++dirty_repos))
    [[ "${no_upstream_flag:-0}" == "1" ]] && ((++no_upstream))
    [[ "${fetch_error_flag:-0}" == "1" ]] && ((++fetch_errors))
  done

  if (( BASE_IS_WORKTREES_ROOT )); then
    local direct_count="${#DIRECT_STATUS_LINES[@]}"
    local nested_count="${#NESTED_STATUS_LINES[@]}"

    if (( direct_count > 0 )); then
      render_table_lines DIRECT_STATUS_LINES "Direct Repos"
    fi
    if (( direct_count > 0 && nested_count > 0 )); then
      echo
    fi
    if (( nested_count > 0 )); then
      render_table_lines NESTED_STATUS_LINES "Nested Worktrees"
    fi
  else
    render_table_lines ALL_STATUS_LINES
  fi

  echo
  echo "repos:${#ALL_STATUS_LINES[@]} behind:$behind_repos dirty:$dirty_repos no-upstream:$no_upstream fetch-errors:$fetch_errors"
}

run_pull() {
  local base="."
  local include_dirty=0
  local ff_only=1
  local no_fetch=0
  local jobs
  jobs="$(default_jobs)"
  local ttl="${GIT_WORKSPACE_FETCH_TTL_SECONDS:-120}"
  local force_fetch=0
  local -a extra_pull_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-dirty)
        include_dirty=1
        ;;
      --no-ff-only)
        ff_only=0
        ;;
      --no-fetch)
        no_fetch=1
        ;;
      --ttl)
        shift
        [[ $# -gt 0 ]] || die "--ttl requires a number"
        ttl="$1"
        ;;
      --ttl=*)
        ttl="${1#--ttl=}"
        ;;
      --force-fetch)
        force_fetch=1
        ;;
      --jobs|-j)
        shift
        [[ $# -gt 0 ]] || die "--jobs requires a number"
        jobs="$1"
        ;;
      --jobs=*)
        jobs="${1#--jobs=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        extra_pull_args+=("$@")
        break
        ;;
      *)
        base="$1"
        ;;
    esac
    shift
  done

  [[ "$jobs" =~ ^[0-9]+$ ]] || die "--jobs must be an integer"
  ((jobs >= 1)) || die "--jobs must be >= 1"
  [[ "$ttl" =~ ^[0-9]+$ ]] || die "--ttl must be an integer"
  ((ttl >= 0)) || die "--ttl must be >= 0"

  warn_no_flock_parallel

  discover_repos "$base" || die "not a directory: $base"
  if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "No git repos found."
    return 0
  fi

  local tmp
  tmp="$(mktemp_dir)" || die "failed to create temp dir"

  CLEANUP_DIRS+=("$tmp")

  pool_setup "$jobs"

  local idx=0
  local repo
  for repo in "${REPOS[@]}"; do
    local display_path
    display_path="$(relpath "$BASE_ABS" "$repo")"

    (
      set +e
      if [[ ${#extra_pull_args[@]} -gt 0 ]]; then
        pull_job "$repo" "$display_path" "$include_dirty" "$ff_only" "$no_fetch" "$ttl" "$force_fetch" "${extra_pull_args[@]}"
      else
        pull_job "$repo" "$display_path" "$include_dirty" "$ff_only" "$no_fetch" "$ttl" "$force_fetch"
      fi
      echo "$?" >"$tmp/$idx.rc"
      exit 0
    ) >"$tmp/$idx.out" 2>&1 &

    pool_throttle "$!"

    ((++idx))
  done

  pool_wait_all

  local pulled=0
  local skipped_dirty=0
  local skipped_detached=0
  local skipped_no_remote=0
  local skipped_up_to_date=0
  local failed=0

  for ((idx = 0; idx < ${#REPOS[@]}; idx++)); do
    if [[ -f "$tmp/$idx.out" ]]; then
      cat "$tmp/$idx.out"
      echo
    fi

    local code=""
    if [[ -f "$tmp/$idx.rc" ]]; then
      code="$(<"$tmp/$idx.rc")"
    else
      code="1"
    fi

    case "$code" in
      "$RC_OK") ((++pulled)) ;;
      "$RC_SKIP_UP_TO_DATE") ((++skipped_up_to_date)) ;;
      "$RC_SKIP_DETACHED") ((++skipped_detached)) ;;
      "$RC_SKIP_DIRTY") ((++skipped_dirty)) ;;
      "$RC_SKIP_NO_REMOTE") ((++skipped_no_remote)) ;;
      *) ((++failed)) ;;
    esac
  done

  echo "pulled:$pulled skipped-up-to-date:$skipped_up_to_date skipped-dirty:$skipped_dirty skipped-detached:$skipped_detached skipped-no-remote:$skipped_no_remote failed:$failed"
}

main() {
  command -v git >/dev/null 2>&1 || die "git is not installed"

  local cmd="status"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      status|report)
        cmd="status"
        shift
        ;;
      pull)
        cmd="pull"
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        cmd="status"
        ;;
    esac
  fi

  case "$cmd" in
    status) print_status "$@" ;;
    pull) run_pull "$@" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
