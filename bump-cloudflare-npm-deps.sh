#!/usr/bin/env bash
# 批量将 workers-world org 各仓 package.json 中的 Cloudflare 相关 npm 依赖升至 npm latest 并开 PR。
# 用法：
#   ./bump-cloudflare-npm-deps.sh --check [--remote]
#   ./bump-cloudflare-npm-deps.sh --apply [--dry-run]
#   ./bump-cloudflare-npm-deps.sh --remote --apply [--dry-run]
#   ./bump-cloudflare-npm-deps.sh --remote --apply --repo mok1 [--dry-run]
# 环境：--remote 开 PR 需 gh + GH_TOKEN（PAT repo）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-release-branch.sh
source "$ROOT/resolve-release-branch.sh"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-$ROOT/cloudflare-npm-deps.allowlist}"
ISSUE_REPO="${ISSUE_REPO:-workers-world/worker-support-action}"

EXCLUDE=(cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs framework_sdk_worker)
LOCAL_EXCLUDE=(templates framework_sdk_worker cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs)

MODE="check"
REMOTE=0
DRY_RUN=0
SINGLE_REPO=""
CREATE_ISSUE=0

usage() {
  cat <<'EOF'
用法:
  ./bump-cloudflare-npm-deps.sh --check [--remote] [--create-issue]
  ./bump-cloudflare-npm-deps.sh --apply [--dry-run]
  ./bump-cloudflare-npm-deps.sh --remote --apply [--repo NAME] [--dry-run]

选项:
  --check              列出需升级 Cloudflare npm 依赖的仓
  --apply              改写 package.json（及 lockfile）并 --remote 时开 PR
  --remote             遍历 workers-world org（clone + 开 PR）
  --repo NAME          --remote 时只处理单个仓
  --create-issue       --check 且有过期仓时在 ISSUE_REPO 开 issue
  --dry-run            只打印将改动的内容
  --allowlist FILE     依赖白名单（默认 cloudflare-npm-deps.allowlist）

环境:
  ALLOWLIST_FILE       白名单路径
  GH_TOKEN             gh CLI、clone 私有仓、开 PR（org PAT）
  NODE_AUTH_TOKEN      GitHub Packages（通常与 GH_TOKEN 相同；见各仓 .npmrc）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --remote) REMOTE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --create-issue) CREATE_ISSUE=1; shift ;;
    --allowlist)
      ALLOWLIST_FILE="${2:?}"
      shift 2
      ;;
    --repo)
      SINGLE_REPO="${2:?}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" == "apply" && "$REMOTE" -eq 0 ]]; then
  echo "无效组合：--apply 需与 --remote 联用（org 批量升级）" >&2
  usage
  exit 1
fi

if [[ ! -f "$ALLOWLIST_FILE" ]]; then
  echo "缺少 allowlist: $ALLOWLIST_FILE" >&2
  exit 1
fi

read_allowlist() {
  grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | grep -v '^[[:space:]]*$' || true
}

is_excluded() {
  local name="$1"
  local e
  for e in "${EXCLUDE[@]}"; do
    [[ "$name" == "$e" ]] && return 0
  done
  return 1
}

ensure_gh_git_auth() {
  if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    gh auth setup-git
  fi
}

ensure_git_identity() {
  if [[ -z "$(git config --get user.email 2>/dev/null || true)" ]]; then
    git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi
  if [[ -z "$(git config --get user.name 2>/dev/null || true)" ]]; then
    git config --global user.name "github-actions[bot]"
  fi
}

ensure_npm_registry_auth() {
  if [[ -n "${GH_TOKEN:-}" && -z "${NODE_AUTH_TOKEN:-}" ]]; then
    export NODE_AUTH_TOKEN="$GH_TOKEN"
  fi
}

repo_is_archived() {
  local name="$1"
  [[ "$(gh repo view "workers-world/$name" --json isArchived -q .isArchived 2>/dev/null || echo false)" == "true" ]]
}

clone_org_repo() {
  local name="$1"
  local dest="$2"
  local shallow="${3:-}"
  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
    if [[ "$shallow" == "shallow" ]]; then
      gh repo clone "workers-world/$name" "$dest" -- --depth 1 --quiet
    else
      gh repo clone "workers-world/$name" "$dest" -- --quiet
    fi
  else
    if [[ "$shallow" == "shallow" ]]; then
      git clone --depth 1 --quiet "https://github.com/workers-world/${name}.git" "$dest"
    else
      git clone --quiet "https://github.com/workers-world/${name}.git" "$dest"
    fi
  fi
}

cleanup_workdir() {
  local dir="${1:-}"
  if [[ -n "$dir" ]]; then
    rm -rf "$dir"
  fi
  trap - RETURN
}

# 输出需升级项：每行 pkg|section|current|latest
list_upgrades_for_repo() {
  local repo_dir="$1"
  local pkg
  if [[ ! -f "$repo_dir/package.json" ]]; then
    return 0
  fi
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    node "$ROOT/.bump-cloudflare-npm-deps-lib.mjs" list-one "$repo_dir/package.json" "$pkg" 2>/dev/null || true
  done < <(read_allowlist)
}

count_upgrades() {
  local repo_dir="$1"
  list_upgrades_for_repo "$repo_dir" | grep -c . || true
}

check_repo_dir() {
  local repo_dir="$1"
  local name="$2"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "STALE $name: $line"
  done < <(list_upgrades_for_repo "$repo_dir")
  local n
  n="$(count_upgrades "$repo_dir")"
  [[ "$n" -gt 0 ]]
}

pr_body() {
  local summary_text="$1"
  local lockfile_note="${2:-}"
  cat <<EOF
## Summary
- 将 Cloudflare 相关 npm 依赖升至 [npm latest](https://www.npmjs.com/)（见 \`cloudflare-npm-deps.allowlist\`）
- 已按仓内现有 lockfile 工具更新 lockfile（如有）
${lockfile_note}

## 升级项
${summary_text}

## 合并后验证
- [ ] \`npm run check && npm test\` 已通过 CI
- [ ] \`wrangler\` 主版本若变更：确认 deploy / 本地 \`wrangler dev\` 无回归

## Deploy
merge → Release PR → \`master\` → CF Builds 自动 deploy（Agent 不代为 deploy）

---
Linear: WW-49 · workers-world/worker-support-action#6
EOF
}

update_lockfile() {
  local repo_dir="$1"
  ensure_npm_registry_auth
  if [[ -f "$repo_dir/pnpm-lock.yaml" ]]; then
    (cd "$repo_dir" && corepack enable pnpm 2>/dev/null || true)
    (cd "$repo_dir" && pnpm install --no-frozen-lockfile >&2) || return 1
  elif [[ -f "$repo_dir/yarn.lock" ]]; then
    (cd "$repo_dir" && corepack enable yarn 2>/dev/null || true)
    (cd "$repo_dir" && { yarn install --mode update-lockfile 2>/dev/null || yarn install; } >&2) || return 1
  elif [[ -f "$repo_dir/package-lock.json" ]] || [[ -f "$repo_dir/npm-shrinkwrap.json" ]]; then
    if ! (cd "$repo_dir" && npm install --package-lock-only --no-audit --no-fund >&2); then
      (cd "$repo_dir" && npm install --no-audit --no-fund >&2) || return 1
    fi
  else
    return 0
  fi
  return 0
}

apply_package_json_upgrades() {
  local repo_dir="$1"
  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    node "$ROOT/.bump-cloudflare-npm-deps-lib.mjs" apply-one "$repo_dir/package.json" "$pkg" || true
  done < <(read_allowlist)
}

apply_upgrades_in_repo() {
  local repo_dir="$1"
  local n=0 lockfile_ok=1
  n="$(count_upgrades "$repo_dir")"
  [[ "$n" -eq 0 ]] && return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    list_upgrades_for_repo "$repo_dir" | while IFS='|' read -r pkg section cur lat; do
      echo "DRY-RUN $repo_dir: $pkg ($section) $cur -> $lat" >&2
    done
    return 0
  fi
  apply_package_json_upgrades "$repo_dir"
  if ! update_lockfile "$repo_dir"; then
    echo "WARN $(basename "$repo_dir"): lockfile 更新失败，将仅提交 package.json（需 NODE_AUTH_TOKEN / GitHub Packages）" >&2
    lockfile_ok=0
  fi
  if [[ "$lockfile_ok" -eq 0 ]]; then
    return 2
  fi
  return 0
}

open_remote_pr() {
  local name="$1"
  local repo_dir="$2"
  local branch bump_branch pr_url n today upgrade_summary="" lockfile_note=""
  n="$(count_upgrades "$repo_dir")"
  if [[ "$n" -eq 0 ]]; then
    echo "SKIP $name: 无待升级 Cloudflare npm 依赖" >&2
    return 1
  fi
  if repo_is_archived "$name"; then
    echo "SKIP $name: archived 仓库无法开 PR" >&2
    return 1
  fi
  while IFS='|' read -r pkg section cur lat; do
    [[ -z "$pkg" ]] && continue
    upgrade_summary+="  - \`$pkg\` ($section): $cur → $lat"$'\n'
  done < <(list_upgrades_for_repo "$repo_dir")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    apply_upgrades_in_repo "$repo_dir" || true
    echo "DRY-RUN PR workers-world/$name ($n packages)" >&2
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "SKIP $name: 需要 gh CLI" >&2
    return 1
  fi
  branch="$(resolve_release_branch "$repo_dir")" || {
    echo "SKIP $name: 无法解析 dev 分支" >&2
    return 1
  }
  today="$(date -u +%Y-%m-%d)"
  bump_branch="chore/bump-cloudflare-npm-deps-${today}"
  git -C "$repo_dir" fetch origin "$branch" --quiet
  git -C "$repo_dir" checkout -B "$bump_branch" "origin/$branch" --quiet
  apply_package_json_upgrades "$repo_dir"
  if ! update_lockfile "$repo_dir"; then
    echo "WARN $name: lockfile 更新失败，将仅提交 package.json" >&2
    lockfile_note=$'- ⚠️ lockfile 未能自动刷新（常见原因：GitHub Packages 认证）；请合并后在本地运行 install 并补交 lockfile\n'
  fi
  git -C "$repo_dir" add package.json
  [[ -f "$repo_dir/package-lock.json" ]] && git -C "$repo_dir" add package-lock.json
  [[ -f "$repo_dir/pnpm-lock.yaml" ]] && git -C "$repo_dir" add pnpm-lock.yaml
  [[ -f "$repo_dir/yarn.lock" ]] && git -C "$repo_dir" add yarn.lock
  if git -C "$repo_dir" diff --staged --quiet; then
    echo "FAIL $name: bump 后无 staged 变更（install 可能失败且 package.json 未变）" >&2
    git -C "$repo_dir" checkout -f "origin/$branch" --quiet 2>/dev/null || true
    git -C "$repo_dir" branch -D "$bump_branch" 2>/dev/null || true
    return 2
  fi
  if ! git -C "$repo_dir" commit -m "chore: bump Cloudflare npm deps to latest" --quiet; then
    echo "FAIL $name: commit 失败" >&2
    return 2
  fi
  push_err=""
  if ! push_err="$(git -C "$repo_dir" push -u origin "$bump_branch" 2>&1)"; then
    if repo_is_archived "$name" || grep -qiE 'archived|Repository is archived' <<< "$push_err"; then
      echo "SKIP $name: archived 仓库无法 push" >&2
      return 1
    fi
    echo "FAIL $name: push 失败 — ${push_err}" >&2
    return 2
  fi
  pr_url="$(gh pr create \
    --repo "workers-world/$name" \
    --base "$branch" \
    --head "$bump_branch" \
    --title "chore: bump Cloudflare npm deps to latest" \
    --body "$(pr_body "$upgrade_summary" "$lockfile_note")")"
  echo "PR $name: $pr_url" >&2
  printf 'PR_URL:%s\n' "$pr_url"
  return 0
}

run_remote_apply() {
  local workdir="" pr_count=0 skip_count=0 fail_count=0
  local name pr_line
  local -a pr_urls=()
  workdir="$(mktemp -d)"
  trap "cleanup_workdir '${workdir}'" RETURN

  ensure_gh_git_auth
  ensure_git_identity
  ensure_npm_registry_auth

  process_one() {
    local name="$1"
    local dir="$workdir/$name"
    local pr_line rc=0
    [[ ! -f "$dir/package.json" ]] && {
      echo "SKIP $name: 无 package.json" >&2
      skip_count=$((skip_count + 1))
      return 0
    }
    pr_line="$(open_remote_pr "$name" "$dir")" || rc=$?
    if [[ "$rc" -eq 0 && "$pr_line" == PR_URL:http* ]]; then
      pr_urls+=("${pr_line#PR_URL:}")
      pr_count=$((pr_count + 1))
    elif [[ "$rc" -eq 2 ]]; then
      fail_count=$((fail_count + 1))
    else
      skip_count=$((skip_count + 1))
    fi
  }

  if [[ -n "$SINGLE_REPO" ]]; then
    if ! clone_org_repo "$SINGLE_REPO" "$workdir/$SINGLE_REPO"; then
      echo "FAIL $SINGLE_REPO: clone failed"
      cleanup_workdir "$workdir"
      exit 1
    fi
    process_one "$SINGLE_REPO"
  else
    for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
      is_excluded "$name" && continue
      if ! clone_org_repo "$name" "$workdir/$name" 2>/dev/null; then
        echo "FAIL $name: clone failed"
        fail_count=$((fail_count + 1))
        continue
      fi
      process_one "$name"
    done
  fi

  echo "remote summary: pr=$pr_count skip=$skip_count fail=$fail_count"
  if [[ ${#pr_urls[@]} -gt 0 ]]; then
    printf 'PR URLs:\n'
    printf '%s\n' "${pr_urls[@]}"
  fi
  cleanup_workdir "$workdir"
  if [[ "$fail_count" -gt 0 ]]; then
    return 1
  fi
  return 0
}

run_check_remote() {
  local workdir="" stale_count=0 repo_count=0
  local -a stale_lines=()
  workdir="$(mktemp -d)"
  trap "cleanup_workdir '${workdir}'" RETURN

  ensure_gh_git_auth

  for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
    is_excluded "$name" && continue
    clone_org_repo "$name" "$workdir/$name" shallow 2>/dev/null || {
      echo "SKIP $name: clone failed"
      continue
    }
    repo_count=$((repo_count + 1))
    [[ ! -f "$workdir/$name/package.json" ]] && continue
    if check_repo_dir "$workdir/$name" "$name"; then
      stale_count=$((stale_count + 1))
      stale_lines+=("- \`$name\`")
      while IFS='|' read -r pkg section cur lat; do
        [[ -z "$pkg" ]] && continue
        stale_lines+=("  - \`$pkg\`: $cur → $lat")
      done < <(list_upgrades_for_repo "$workdir/$name")
    fi
  done

  echo "remote check: $repo_count repos scanned, $stale_count need npm upgrades"
  if [[ "$CREATE_ISSUE" -eq 1 && "$stale_count" -gt 0 && "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create \
      --repo "$ISSUE_REPO" \
      --title "Cloudflare npm 依赖可升级：${stale_count} 个仓" \
      --body "修复：\`workflow_dispatch\` 触发 [bump-cloudflare-deps.yml](https://github.com/${ISSUE_REPO}/actions/workflows/bump-cloudflare-deps.yml)，或 \`./bump-cloudflare-npm-deps.sh --remote --apply\`。

待升级清单：
$(printf '%s\n' "${stale_lines[@]}")" \
      >/dev/null
    echo "issue created (remote stale deps)"
  fi
  cleanup_workdir "$workdir"
  [[ "$stale_count" -eq 0 ]]
}

main() {
  echo "mode=$MODE remote=$REMOTE dry_run=$DRY_RUN allowlist=$ALLOWLIST_FILE"
  if [[ "$MODE" == "apply" ]]; then
    run_remote_apply
    exit $?
  fi
  if [[ "$REMOTE" -eq 1 ]]; then
    run_check_remote
    exit $?
  fi
  echo "--check 需加 --remote（org 扫描）" >&2
  exit 1
}

main
