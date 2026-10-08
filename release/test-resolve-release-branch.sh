#!/usr/bin/env bash
# Unit tests for resolve-release-branch.sh (local bare repos, no network).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-release-branch.sh
source "$SCRIPT_DIR/resolve-release-branch.sh"

tmpdir=""
cleanup() {
  [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
}
trap cleanup EXIT

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $msg (got=$got want=$want)" >&2
    exit 1
  fi
}

setup_fixture() {
  local name="$1" default_branch="$2" release_file="${3-}" branches_csv="${4-}"
  local bare="$tmpdir/${name}.git" clone="$tmpdir/${name}"
  git init -b "$default_branch" --bare "$bare" >/dev/null
  git clone --quiet "$bare" "$clone"
  git -C "$clone" config user.email "test@test"
  git -C "$clone" config user.name "test"
  git -C "$clone" checkout -b "$default_branch" 2>/dev/null || git -C "$clone" checkout "$default_branch"
  printf 'init\n' > "$clone/README"
  git -C "$clone" add README
  git -C "$clone" commit -m "init" --quiet
  git -C "$clone" push -u origin "$default_branch" >/dev/null
  if [[ -n "$release_file" ]]; then
    mkdir -p "$clone/.github"
    printf '%s\n' "$release_file" > "$clone/.github/RELEASE_BRANCH"
    git -C "$clone" add .github/RELEASE_BRANCH
    git -C "$clone" commit -m "release branch file" --quiet
    git -C "$clone" push origin "$default_branch" >/dev/null
  fi
  IFS=',' read -r -a branches <<< "$branches_csv"
  for b in "${branches[@]}"; do
    [[ -z "$b" ]] && continue
    [[ "$b" == "$default_branch" ]] && continue
    git -C "$clone" branch "$b" "$default_branch" >/dev/null
    git -C "$clone" push origin "$b" >/dev/null
  done
  git -C "$bare" symbolic-ref HEAD "refs/heads/$default_branch" >/dev/null
  git -C "$clone" remote set-url origin "$bare"
  git -C "$clone" fetch origin >/dev/null
  git -C "$clone" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$default_branch" >/dev/null
  echo "$clone"
}

tmpdir="$(mktemp -d)"
echo "test-resolve-release-branch: using $tmpdir"

# Default dev branch wins over stale RELEASE_BRANCH file.
repo="$(setup_fixture gold-price-worker dev_00_17_00 dev_00_14_00 "dev_00_17_00,dev_00_14_00")"
out="$(resolve_release_branch "$repo" 2>/dev/null)"
assert_eq "$out" "dev_00_17_00" "prefer GitHub default over stale RELEASE_BRANCH"
warn="$(resolve_release_branch "$repo" 2>&1 >/dev/null || true)"
if ! grep -q 'RELEASE_BRANCH=dev_00_14_00' <<< "$warn"; then
  echo "FAIL: expected warning mentioning stale RELEASE_BRANCH" >&2
  exit 1
fi

# Agrees: file matches default, no surprise branch change.
repo="$(setup_fixture counter-worker dev_00_12_00 dev_00_12_00 "dev_00_12_00,dev_00_08_00")"
out="$(resolve_release_branch "$repo" 2>/dev/null)"
assert_eq "$out" "dev_00_12_00" "unchanged when RELEASE_BRANCH matches default"

# Non-dev default: still honor RELEASE_BRANCH when it exists on origin.
repo="$(setup_fixture legacy-worker master dev_00_05_00 "master,dev_00_05_00")"
out="$(resolve_release_branch "$repo" 2>/dev/null)"
assert_eq "$out" "dev_00_05_00" "non-dev default keeps RELEASE_BRANCH behavior"

echo "OK: all resolve-release-branch tests passed"
