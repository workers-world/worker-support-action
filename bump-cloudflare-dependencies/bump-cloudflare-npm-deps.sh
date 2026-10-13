#!/usr/bin/env bash
# 批量将 workers-world org 各仓 package.json 中的 Cloudflare 相关 npm 依赖升至兼容版本并开 PR。
# WW-239: peer / lock / ci 兼容闸 — 不可解析或已知 peer 冲突时不建 PR。
# 用法：
#   ./bump-cloudflare-npm-deps.sh --check [--remote]
#   ./bump-cloudflare-npm-deps.sh --apply [--dry-run]
#   ./bump-cloudflare-npm-deps.sh --remote --apply [--dry-run]
#   ./bump-cloudflare-npm-deps.sh --remote --apply --repo mok1 [--dry-run]
# 环境：--remote 开 PR 需 gh + GH_TOKEN（PAT repo）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../release/resolve-release-branch.sh
source "$REPO_ROOT/release/resolve-release-branch.sh"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-$SCRIPT_DIR/cloudflare-npm-deps.allowlist}"
ISSUE_REPO="${ISSUE_REPO:-workers-world/worker-support-action}"
LIB_MJS="$SCRIPT_DIR/.bump-cloudflare-npm-deps-lib.mjs"

EXCLUDE=(cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs framework_sdk_worker)
LOCAL_EXCLUDE=(templates framework_sdk_worker cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs)

MODE="check"
REMOTE=0
DRY_RUN=0
SINGLE_REPO=""
CREATE_ISSUE=0
CREATE_BLOCKED_ISSUE=0
ALLOW_PACKAGE_JSON_ONLY=0
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}"

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
  --create-blocked-issue  --apply 时汇总 lock/ci/peer 阻断仓并开说明 issue
  --allow-package-json-only  lock 失败仍提交 package.json（默认关闭，WW-239）
  --dry-run            只打印将改动的内容
  --allowlist FILE     依赖白名单（默认 cloudflare-npm-deps.allowlist）

环境:
  ALLOWLIST_FILE       白名单路径
  GH_TOKEN             gh CLI、clone 私有仓、开 PR（org PAT）
  NODE_AUTH_TOKEN      GitHub Packages（通常与 GH_TOKEN 相同；见各仓 .npmrc）
  SMOKE_TIMEOUT        开 PR 前 npm ci / check / test / lint 超时秒数（默认 600）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --remote) REMOTE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --create-issue) CREATE_ISSUE=1; shift ;;
    --create-blocked-issue) CREATE_BLOCKED_ISSUE=1; shift ;;
    --allow-package-json-only) ALLOW_PACKAGE_JSON_ONLY=1; shift ;;
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
  grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | grep -v '^[[:space:]]*$' | awk '{print $1}' || true
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

# 输出需升级项：每行 pkg|section|current|target|versionSource
list_upgrades_for_repo() {
  local repo_dir="$1"
  if [[ ! -f "$repo_dir/package.json" ]]; then
    return 0
  fi
  node "$LIB_MJS" list-upgrades "$repo_dir" "$ALLOWLIST_FILE" 2>/dev/null || true
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

format_upgrade_summary_md() {
  local repo_dir="$1"
  local line pkg section cur target src
  while IFS='|' read -r pkg section cur target src; do
    [[ -z "$pkg" ]] && continue
    echo "  - \`$pkg\` ($section): $cur → $target (source: \`$src\`)"
  done < <(list_upgrades_for_repo "$repo_dir")
}

pr_body() {
  local repo_dir="$1"
  local lock_result="$2"
  local smoke_result="$3"
  local upgrade_summary
  upgrade_summary="$(format_upgrade_summary_md "$repo_dir")"
  cat <<EOF
## Summary
- 将 Cloudflare 相关 npm 依赖升至 **peer / semver 兼容** 的最高版本（见 \`cloudflare-npm-deps.allowlist\`，WW-239）
- Lockfile 刷新: **${lock_result}**
- 开 PR 前 smoke（\`npm ci\` + 仓内 check/test/lint）: **${smoke_result}**

## 升级项与版本来源
${upgrade_summary}

## 合并后验证
- [ ] \`npm run check && npm test\` 已通过 CI
- [ ] \`wrangler\` 主版本若变更：确认 deploy / 本地 \`wrangler dev\` 无回归

## Deploy
merge → Release PR → \`master\` → CF Builds 自动 deploy（Agent 不代为 deploy）

---
Linear: WW-239 · workers-world/worker-support-action#27 · WW-49
EOF
}

detect_package_manager() {
  local repo_dir="$1"
  if [[ -f "$repo_dir/pnpm-lock.yaml" ]]; then
    echo pnpm
  elif [[ -f "$repo_dir/yarn.lock" ]]; then
    echo yarn
  elif [[ -f "$repo_dir/package-lock.json" ]] || [[ -f "$repo_dir/npm-shrinkwrap.json" ]]; then
    echo npm
  else
    echo none
  fi
}

run_install_logged() {
  local log_file="${1:-}"
  shift
  if [[ -n "$log_file" ]]; then
    "$@" >>"$log_file" 2>&1
  else
    "$@" >&2
  fi
}

update_lockfile() {
  local repo_dir="$1"
  local log_file="${2:-}"
  ensure_npm_registry_auth
  if [[ -n "$log_file" ]]; then
    : >"$log_file"
  fi
  case "$(detect_package_manager "$repo_dir")" in
    pnpm)
      (cd "$repo_dir" && corepack enable pnpm 2>/dev/null || true)
      run_install_logged "$log_file" bash -c "cd $(printf '%q' "$repo_dir") && pnpm install --no-frozen-lockfile"
      ;;
    yarn)
      (cd "$repo_dir" && corepack enable yarn 2>/dev/null || true)
      run_install_logged "$log_file" bash -c "cd $(printf '%q' "$repo_dir") && { yarn install --mode update-lockfile 2>/dev/null || yarn install; }"
      ;;
    npm)
      if ! run_install_logged "$log_file" bash -c "cd $(printf '%q' "$repo_dir") && npm install --package-lock-only --no-audit --no-fund"; then
        run_install_logged "$log_file" bash -c "cd $(printf '%q' "$repo_dir") && npm install --no-audit --no-fund"
      fi
      ;;
    none)
      return 0
      ;;
  esac
}

run_pre_pr_smoke() {
  local repo_dir="$1"
  local log_file="${2:-}"
  local pm pkg_json scripts script
  pm="$(detect_package_manager "$repo_dir")"
  pkg_json="$repo_dir/package.json"
  [[ -f "$pkg_json" ]] || return 1

  smoke_step() {
    local label="$1"
    shift
    echo "SMOKE $label" >&2
    if [[ -n "$log_file" ]]; then
      echo "--- $label ---" >>"$log_file"
      if ! timeout "$SMOKE_TIMEOUT" "$@" >>"$log_file" 2>&1; then
        return 1
      fi
    else
      if ! timeout "$SMOKE_TIMEOUT" "$@" >&2; then
        return 1
      fi
    fi
    return 0
  }

  case "$pm" in
    pnpm)
      smoke_step "pnpm install --frozen-lockfile" bash -c "cd $(printf '%q' "$repo_dir") && pnpm install --frozen-lockfile" || return 1
      ;;
    yarn)
      smoke_step "yarn install --immutable" bash -c "cd $(printf '%q' "$repo_dir") && yarn install --immutable" || return 1
      ;;
    npm|none)
      if [[ -f "$repo_dir/package-lock.json" ]]; then
        smoke_step "npm ci" bash -c "cd $(printf '%q' "$repo_dir") && npm ci --no-audit --no-fund" || return 1
      elif [[ "$pm" == "npm" ]]; then
        smoke_step "npm install" bash -c "cd $(printf '%q' "$repo_dir") && npm install --no-audit --no-fund" || return 1
      fi
      ;;
  esac

  scripts="$(node -e "const p=require(process.argv[1]); console.log(Object.keys(p.scripts||{}).join(' '))" "$pkg_json")"
  for script in check test lint; do
    if grep -qw "$script" <<< "$scripts"; then
      smoke_step "npm run $script" bash -c "cd $(printf '%q' "$repo_dir") && npm run $script" || return 1
    fi
  done
  return 0
}

apply_package_json_upgrades() {
  local repo_dir="$1"
  node "$LIB_MJS" apply-upgrades "$repo_dir" "$ALLOWLIST_FILE"
}

reset_repo_branch() {
  local repo_dir="$1"
  local branch="$2"
  local bump_branch="$3"
  git -C "$repo_dir" checkout -f "origin/$branch" --quiet 2>/dev/null || true
  git -C "$repo_dir" branch -D "$bump_branch" 2>/dev/null || true
}

apply_upgrades_in_repo() {
  local repo_dir="$1"
  local n=0
  n="$(count_upgrades "$repo_dir")"
  [[ "$n" -eq 0 ]] && return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    list_upgrades_for_repo "$repo_dir" | while IFS='|' read -r pkg section cur target src; do
      echo "DRY-RUN $repo_dir: $pkg ($section) $cur -> $target ($src)" >&2
    done
    return 0
  fi
  apply_package_json_upgrades "$repo_dir"
  if ! update_lockfile "$repo_dir"; then
    if [[ "$ALLOW_PACKAGE_JSON_ONLY" -eq 1 ]]; then
      echo "WARN $(basename "$repo_dir"): lockfile 更新失败，--allow-package-json-only 已启用" >&2
      return 2
    fi
    echo "BLOCK $(basename "$repo_dir"): lockfile 更新失败，跳过 PR（WW-239）" >&2
    return 3
  fi
  return 0
}

open_remote_pr() {
  local name="$1"
  local repo_dir="$2"
  local branch bump_branch pr_url n today
  local lock_result="skipped" smoke_result="skipped"
  local lock_log smoke_log
  lock_log="$(mktemp)"
  smoke_log="$(mktemp)"
  n="$(count_upgrades "$repo_dir")"
  if [[ "$n" -eq 0 ]]; then
    echo "SKIP $name: 无待升级 Cloudflare npm 依赖" >&2
    rm -f "$lock_log" "$smoke_log"
    return 1
  fi
  if repo_is_archived "$name"; then
    echo "SKIP $name: archived 仓库无法开 PR" >&2
    rm -f "$lock_log" "$smoke_log"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    apply_upgrades_in_repo "$repo_dir" || true
    echo "DRY-RUN PR workers-world/$name ($n packages)" >&2
    rm -f "$lock_log" "$smoke_log"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "SKIP $name: 需要 gh CLI" >&2
    rm -f "$lock_log" "$smoke_log"
    return 1
  fi
  branch="$(resolve_release_branch "$repo_dir")" || {
    echo "SKIP $name: 无法解析 dev 分支" >&2
    rm -f "$lock_log" "$smoke_log"
    return 1
  }
  today="$(date -u +%Y-%m-%d)"
  bump_branch="chore/bump-cloudflare-npm-deps-${today}"
  git -C "$repo_dir" fetch origin "$branch" --quiet
  git -C "$repo_dir" checkout -B "$bump_branch" "origin/$branch" --quiet

  apply_package_json_upgrades "$repo_dir"
  if ! update_lockfile "$repo_dir" "$lock_log"; then
    lock_result="failed"
    echo "BLOCK $name: lockfile 更新失败，不建 PR" >&2
    tail -20 "$lock_log" >&2 || true
    if [[ "$ALLOW_PACKAGE_JSON_ONLY" -eq 1 ]]; then
      lock_result="failed (package.json-only override)"
    else
      reset_repo_branch "$repo_dir" "$branch" "$bump_branch"
      rm -f "$lock_log" "$smoke_log"
      echo "BLOCK_REASON $name|lockfile_failed" >&2
      return 4
    fi
  else
    lock_result="ok"
  fi

  if ! run_pre_pr_smoke "$repo_dir" "$smoke_log"; then
    smoke_result="failed"
    echo "BLOCK $name: pre-PR smoke 失败，不建 PR" >&2
    tail -30 "$smoke_log" >&2 || true
    reset_repo_branch "$repo_dir" "$branch" "$bump_branch"
    rm -f "$lock_log" "$smoke_log"
    echo "BLOCK_REASON $name|smoke_failed" >&2
    return 4
  fi
  smoke_result="ok"

  git -C "$repo_dir" add package.json
  [[ -f "$repo_dir/package-lock.json" ]] && git -C "$repo_dir" add package-lock.json
  [[ -f "$repo_dir/pnpm-lock.yaml" ]] && git -C "$repo_dir" add pnpm-lock.yaml
  [[ -f "$repo_dir/yarn.lock" ]] && git -C "$repo_dir" add yarn.lock
  if git -C "$repo_dir" diff --staged --quiet; then
    echo "FAIL $name: bump 后无 staged 变更" >&2
    reset_repo_branch "$repo_dir" "$branch" "$bump_branch"
    rm -f "$lock_log" "$smoke_log"
    return 2
  fi
  if ! git -C "$repo_dir" commit -m "chore: bump Cloudflare npm deps (peer-aware)" --quiet; then
    echo "FAIL $name: commit 失败" >&2
    rm -f "$lock_log" "$smoke_log"
    return 2
  fi
  push_err=""
  if ! push_err="$(git -C "$repo_dir" push -u origin "$bump_branch" 2>&1)"; then
    if repo_is_archived "$name" || grep -qiE 'archived|Repository is archived' <<< "$push_err"; then
      echo "SKIP $name: archived 仓库无法 push" >&2
      rm -f "$lock_log" "$smoke_log"
      return 1
    fi
    echo "FAIL $name: push 失败 — ${push_err}" >&2
    rm -f "$lock_log" "$smoke_log"
    return 2
  fi
  pr_url="$(gh pr create \
    --repo "workers-world/$name" \
    --base "$branch" \
    --head "$bump_branch" \
    --title "chore: bump Cloudflare npm deps (peer-aware)" \
    --body "$(pr_body "$repo_dir" "$lock_result" "$smoke_result")")"
  echo "PR $name: $pr_url" >&2
  printf 'PR_URL:%s\n' "$pr_url"
  rm -f "$lock_log" "$smoke_log"
  return 0
}

run_remote_apply() {
  local workdir="" pr_count=0 skip_count=0 fail_count=0 block_count=0
  local name pr_line
  local -a pr_urls=()
  local -a blocked_lines=()
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
    elif [[ "$rc" -eq 4 ]]; then
      block_count=$((block_count + 1))
      blocked_lines+=("- \`$name\`: 见日志 BLOCK / BLOCK_REASON")
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

  echo "remote summary: pr=$pr_count skip=$skip_count fail=$fail_count block=$block_count"
  if [[ ${#pr_urls[@]} -gt 0 ]]; then
    printf 'PR URLs:\n'
    printf '%s\n' "${pr_urls[@]}"
  fi
  if [[ "$block_count" -gt 0 ]]; then
    echo "BLOCKED repos (no PR opened):"
    printf '%s\n' "${blocked_lines[@]}"
    if [[ "$CREATE_BLOCKED_ISSUE" -eq 1 && "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
      gh issue create \
        --repo "$ISSUE_REPO" \
        --title "bump-cloudflare-npm-deps: ${block_count} 仓被兼容闸阻断" \
        --body "WW-239：下列仓因 lock / smoke / peer 兼容闸未开 bump PR。请查看 [最近一次 workflow 日志](https://github.com/${ISSUE_REPO}/actions/workflows/bump-cloudflare-deps.yml)。

$(printf '%s\n' "${blocked_lines[@]}")" \
        >/dev/null
      echo "blocked summary issue created"
    fi
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
      while IFS='|' read -r pkg section cur target src; do
        [[ -z "$pkg" ]] && continue
        stale_lines+=("  - \`$pkg\`: $cur → $target ($src)")
      done < <(list_upgrades_for_repo "$workdir/$name")
    fi
  done

  echo "remote check: $repo_count repos scanned, $stale_count need npm upgrades"
  if [[ "$CREATE_ISSUE" -eq 1 && "$stale_count" -gt 0 && "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create \
      --repo "$ISSUE_REPO" \
      --title "Cloudflare npm 依赖可升级：${stale_count} 个仓" \
      --body "修复：\`workflow_dispatch\` 触发 [bump-cloudflare-deps.yml](https://github.com/${ISSUE_REPO}/actions/workflows/bump-cloudflare-deps.yml)，或 \`bump-cloudflare-dependencies/bump-cloudflare-npm-deps.sh --remote --apply\`。

待升级清单：
$(printf '%s\n' "${stale_lines[@]}")" \
      >/dev/null
    echo "issue created (remote stale deps)"
  fi
  cleanup_workdir "$workdir"
  [[ "$stale_count" -eq 0 ]]
}

main() {
  echo "mode=$MODE remote=$REMOTE dry_run=$DRY_RUN allowlist=$ALLOWLIST_FILE allow_pkg_json_only=$ALLOW_PACKAGE_JSON_ONLY"
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
