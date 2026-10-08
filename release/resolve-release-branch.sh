#!/usr/bin/env bash
# Shared release/dev branch resolution for org bump scripts.
# shellcheck shell=bash

is_dev_release_branch() {
  [[ "$1" =~ ^dev_[0-9]+_[0-9]+_[0-9]+$ ]]
}

dev_branch_is_older_than() {
  local a="$1" b="$2"
  is_dev_release_branch "$a" && is_dev_release_branch "$b" \
    && [[ "$a" != "$b" ]] \
    && [[ "$(printf '%s\n' "$a" "$b" | sort -t_ -k2,2n -k3,3n -k4,4n | tail -1)" == "$b" ]]
}

newest_dev_branch_from_remote() {
  local repo_dir="$1"
  git -C "$repo_dir" ls-remote --heads origin 'dev_*' 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^dev_[0-9]+_[0-9]+_[0-9]+$' \
    | sort -t_ -k2,2n -k3,3n -k4,4n \
    | tail -1 || true
}

origin_branch_exists() {
  local repo_dir="$1" branch="$2"
  [[ -n "$branch" ]] || return 1
  git -C "$repo_dir" ls-remote --exit-code --heads origin "refs/heads/${branch}" >/dev/null 2>&1
}

origin_default_branch() {
  local repo_dir="$1"
  local ref name
  ref="$(git -C "$repo_dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/origin/@@' || true)"
  if [[ -n "$ref" ]]; then
    echo "$ref"
    return 0
  fi
  name="$(basename "$repo_dir")"
  if command -v gh >/dev/null 2>&1; then
    gh repo view "workers-world/${name}" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true
  fi
}

warn_release_branch_mismatch() {
  local repo_name="$1" file_branch="$2" default_branch="$3" reason="$4"
  echo "WARN ${repo_name}: .github/RELEASE_BRANCH=${file_branch} 与 GitHub 默认分支 ${default_branch} 不一致（${reason}），采用默认分支 ${default_branch}" >&2
}

# Prints chosen dev release branch on stdout; warnings on stderr.
resolve_release_branch() {
  local repo_dir="$1"
  local repo_name file_branch default_branch newest_dev branch=""

  repo_name="$(basename "$repo_dir")"
  file_branch=""
  if [[ -f "$repo_dir/.github/RELEASE_BRANCH" ]]; then
    file_branch="$(tr -d '[:space:]' < "$repo_dir/.github/RELEASE_BRANCH")"
  fi

  default_branch="$(origin_default_branch "$repo_dir")"
  newest_dev="$(newest_dev_branch_from_remote "$repo_dir")"

  if is_dev_release_branch "$default_branch"; then
    if [[ -n "$file_branch" && "$file_branch" != "$default_branch" ]]; then
      if ! origin_branch_exists "$repo_dir" "$file_branch"; then
        warn_release_branch_mismatch "$repo_name" "$file_branch" "$default_branch" "RELEASE_BRANCH 指向不存在的分支"
      elif dev_branch_is_older_than "$file_branch" "$newest_dev"; then
        warn_release_branch_mismatch "$repo_name" "$file_branch" "$default_branch" "RELEASE_BRANCH 落后于最新 dev_* ${newest_dev}"
      else
        warn_release_branch_mismatch "$repo_name" "$file_branch" "$default_branch" "RELEASE_BRANCH 与默认分支不符"
      fi
    fi
    echo "$default_branch"
    return 0
  fi

  if [[ -n "$file_branch" ]]; then
    if origin_branch_exists "$repo_dir" "$file_branch"; then
      echo "$file_branch"
      return 0
    fi
    echo "WARN ${repo_name}: .github/RELEASE_BRANCH=${file_branch} 在 origin 上不存在，改用最新 dev_*" >&2
  fi

  branch="$newest_dev"
  if [[ -z "$branch" ]]; then
    branch="$(git -C "$repo_dir" branch -a 2>/dev/null \
      | sed 's/^[* ]*//;s|remotes/origin/||' \
      | grep -E '^dev_[0-9]+_[0-9]+_[0-9]+$' \
      | sort -t_ -k2,2n -k3,3n -k4,4n \
      | tail -1 || true)"
  fi
  if [[ -n "$branch" ]]; then
    echo "$branch"
    return 0
  fi
  return 1
}
