#!/usr/bin/env bash
# OSV 驱动的 npm 依赖 CVE 漏洞扫描 + 最小修复版本自动升级（worker-support-action）。
# 检测：osv-scanner 对各仓根 npm lockfile（package-lock.json / npm-shrinkwrap.json）全量扫描。
# 修复：直接依赖 pin 到最低修复版本；传递依赖写 package.json `overrides`；
#       复用 WW-239 同款 lock 刷新 + pre-PR smoke（npm ci + check/test/lint）兼容闸后开 PR。
# Gate N1: 仅 --auto-merge 时启用 squash auto-merge + fleet:ready（默认人工审）。
# 用法：
#   ./bump-vulnerable-npm-deps.sh --check --remote [--create-issue]
#   ./bump-vulnerable-npm-deps.sh --remote --apply [--repo NAME] [--dry-run] [--auto-merge]
#   ./bump-vulnerable-npm-deps.sh --remote --close-superseded [--repo NAME]
# 环境：osv-scanner 需在 PATH（或 OSV_SCANNER_BIN）；--remote 需 gh + GH_TOKEN（org PAT）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../release/resolve-release-branch.sh
source "$REPO_ROOT/release/resolve-release-branch.sh"
VULN_LIB_MJS="$SCRIPT_DIR/.vuln-scan-lib.mjs"
ISSUE_REPO="${ISSUE_REPO:-workers-world/worker-support-action}"
OSV_SCANNER_BIN="${OSV_SCANNER_BIN:-osv-scanner}"
OSV_SCANNER_EXTRA_ARGS="${OSV_SCANNER_EXTRA_ARGS:-}"

# Gate N1 — vulnerable-deps fleet PRs (must match open_remote_pr).
readonly VULN_DEPS_PR_TITLE='fix: bump vulnerable npm deps to patched versions'
readonly VULN_DEPS_BRANCH_PREFIX='chore/fix-vulnerable-deps-'
readonly FLEET_READY_LABEL='fleet:ready'
readonly SUPERSEDE_COMMENT=$'disposition: superseded\n\nGate N1: closing dirty, behind destin, or superseded by a newer `chore/fix-vulnerable-deps-*` head. The weekly vuln scan will open a clean PR when the lock/smoke gates pass.\n\nAutomation: workers-world/worker-support-action'

EXCLUDE=(cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs framework_sdk_worker)

MODE="check"
REMOTE=0
DRY_RUN=0
CREATE_ISSUE=0
AUTO_MERGE=0
CLOSE_SUPERSEDED=0
SINGLE_REPO=""
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}"

usage() {
  cat <<'EOF'
用法:
  ./bump-vulnerable-npm-deps.sh --check --remote [--create-issue] [--repo NAME]
  ./bump-vulnerable-npm-deps.sh --remote --apply [--repo NAME] [--dry-run] [--auto-merge]
  ./bump-vulnerable-npm-deps.sh --remote --close-superseded [--repo NAME] [--dry-run]

选项:
  --check             列出有 CVE 漏洞依赖的仓（OSV 扫描，只读）
  --apply             扫描并把可修复项升到最低修复版本、刷新 lock、smoke 后开 PR
  --close-superseded  关闭 DIRTY / behind / 被较新 vuln-fix head 取代的 PR（Gate N1）
  --remote            遍历 workers-world org（clone + 扫描 + 开 PR）
  --repo NAME         --remote 时只处理单个仓
  --create-issue      --check 且有发现时在 ISSUE_REPO 开 issue
  --auto-merge        开 PR 后启用 Gate N1（squash auto-merge + fleet:ready）；默认人工审
  --dry-run           只打印将改动的内容

环境:
  OSV_SCANNER_BIN        osv-scanner 可执行（默认 PATH 上的 osv-scanner）
  OSV_SCANNER_EXTRA_ARGS 附加 scanner 参数（如 --config=...）
  GH_TOKEN               gh CLI、clone 私有仓、开 PR（org PAT）
  NODE_AUTH_TOKEN        GitHub Packages（通常与 GH_TOKEN 相同）
  SMOKE_TIMEOUT          开 PR 前 npm ci / check / test / lint 超时秒数（默认 600）
  ISSUE_REPO             issue 目标仓（默认 workers-world/worker-support-action）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --remote) REMOTE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --create-issue) CREATE_ISSUE=1; shift ;;
    --auto-merge) AUTO_MERGE=1; shift ;;
    --close-superseded) CLOSE_SUPERSEDED=1; shift ;;
    --repo)
      SINGLE_REPO="${2:?}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" == "apply" && "$REMOTE" -eq 0 ]]; then
  echo "无效组合：--apply 需与 --remote 联用（org 批量）" >&2
  usage
  exit 1
fi

if [[ "$CLOSE_SUPERSEDED" -eq 1 && "$MODE" != "check" ]]; then
  echo "无效组合：--close-superseded 不可与 --apply 联用" >&2
  usage
  exit 1
fi

if [[ "$CLOSE_SUPERSEDED" -eq 1 && "$REMOTE" -eq 0 ]]; then
  echo "无效组合：--close-superseded 需与 --remote 联用" >&2
  usage
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "需要 node 在 PATH（解析 osv JSON / 改写 package.json）" >&2
  exit 1
fi
if ! command -v "$OSV_SCANNER_BIN" >/dev/null 2>&1; then
  echo "找不到 osv-scanner（可设 OSV_SCANNER_BIN 指向可执行文件）" >&2
  exit 1
fi

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

# --- OSV scan ----------------------------------------------------------------

# 扫描仓根 npm lockfile -> osv JSON（空输出 = 无发现）。
scan_repo_osv() {
  local repo_dir="$1"
  local out_json="$2"
  local lockfile
  lockfile="$repo_dir/package-lock.json"
  [[ -f "$lockfile" ]] || lockfile="$repo_dir/npm-shrinkwrap.json"
  if [[ ! -f "$lockfile" ]]; then
    return 2 # 无 npm lockfile（v1 扫描范围：根 npm lock）
  fi
  local rc=0
  # # shellcheck disable=SC2086 — extra args 有意按空格分词
  "$OSV_SCANNER_BIN" scan source --lockfile "$lockfile" $OSV_SCANNER_EXTRA_ARGS --format json \
    >"$out_json" 2>/dev/null || rc=$?
  case "$rc" in
    0|1) return 0 ;;
    *) return 1 ;;
  esac
}

list_findings_for_repo() {
  local repo_dir="$1"
  local osv_json="$2"
  node "$VULN_LIB_MJS" summarize "$repo_dir" "$osv_json" 2>/dev/null || true
}

count_findings() {
  local repo_dir="$1"
  local osv_json="$2"
  list_findings_for_repo "$repo_dir" "$osv_json" | grep -c . || true
}

list_unfixable_for_repo() {
  local repo_dir="$1"
  local osv_json="$2"
  node "$VULN_LIB_MJS" unfixable "$repo_dir" "$osv_json" 2>/dev/null || true
}

# --- lock / smoke（对齐 bump-cloudflare-npm-deps.sh WW-239）--------------------

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

reset_repo_branch() {
  local repo_dir="$1"
  local branch="$2"
  local bump_branch="$3"
  git -C "$repo_dir" checkout -f "origin/$branch" --quiet 2>/dev/null || true
  git -C "$repo_dir" branch -D "$bump_branch" 2>/dev/null || true
}

# --- PR / Gate N1 -------------------------------------------------------------

vuln_deps_head_date_suffix() {
  local head="$1"
  if [[ "$head" == "$VULN_DEPS_BRANCH_PREFIX"* ]]; then
    echo "${head#"$VULN_DEPS_BRANCH_PREFIX"}"
  else
    echo ""
  fi
}

ensure_fleet_ready_label() {
  local name="$1"
  gh label create "$FLEET_READY_LABEL" \
    --repo "workers-world/$name" \
    --color "0E8A16" \
    --description "Gate N1: vulnerable-deps PR ready for destin auto-merge when checks pass" \
    2>/dev/null || true
}

gate_n1_enable_automerge() {
  local name="$1"
  local pr_url="$2"
  local pr_num="${pr_url##*/}"
  if [[ -z "$pr_num" || "$pr_num" == "$pr_url" ]]; then
    echo "WARN $name: 无法从 PR URL 解析 number: $pr_url" >&2
    return 1
  fi
  if ! gh pr merge "$pr_num" --repo "workers-world/$name" --auto --squash >/dev/null 2>&1; then
    echo "WARN $name: enable auto-merge 失败（检查仓库是否允许 auto-merge / PAT 权限）" >&2
  else
    echo "GATE_N1 $name: auto-merge squash enabled for PR #$pr_num" >&2
  fi
  ensure_fleet_ready_label "$name"
  if ! gh pr edit "$pr_num" --repo "workers-world/$name" --add-label "$FLEET_READY_LABEL" >/dev/null 2>&1; then
    echo "WARN $name: 添加 $FLEET_READY_LABEL 失败" >&2
  else
    echo "GATE_N1 $name: label $FLEET_READY_LABEL on PR #$pr_num" >&2
  fi
}

close_vuln_deps_pr_with_supersede_comment() {
  local name="$1"
  local pr_num="$2"
  local reason="$3"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN SUPERSEDE_CLOSE $name#$pr_num ($reason)" >&2
    return 0
  fi
  gh pr comment "$pr_num" --repo "workers-world/$name" --body "$SUPERSEDE_COMMENT" >/dev/null 2>&1 || true
  if gh pr close "$pr_num" --repo "workers-world/$name" --comment "Gate N1: $reason" >/dev/null 2>&1; then
    echo "SUPERSEDE_CLOSE $name#$pr_num ($reason)" >&2
    return 0
  fi
  echo "WARN $name: close PR #$pr_num failed ($reason)" >&2
  return 1
}

close_superseded_vuln_deps_prs_for_repo() {
  local name="$1"
  local keep_head="${2:-}"
  local json line pr_num head state newest_head newest_date head_date
  local -a heads=()
  local close_count=0

  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  if repo_is_archived "$name"; then
    return 0
  fi

  json="$(gh pr list --repo "workers-world/$name" --state open --limit 50 \
    --json number,title,headRefName,mergeable,mergeStateStatus 2>/dev/null || echo '[]')"
  if [[ -z "$json" || "$json" == "[]" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pr_num="$(jq -r '.number' <<< "$line")"
    head="$(jq -r '.headRefName' <<< "$line")"
    state="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<< "$line")"
    if [[ "$(jq -r '.title' <<< "$line")" != "$VULN_DEPS_PR_TITLE" ]]; then
      continue
    fi
    if [[ "$head" != "$VULN_DEPS_BRANCH_PREFIX"* ]]; then
      continue
    fi

    if [[ -n "$keep_head" && "$head" == "$keep_head" ]]; then
      if [[ "$state" == "DIRTY" || "$state" == "BEHIND" ]]; then
        close_vuln_deps_pr_with_supersede_comment "$name" "$pr_num" "mergeStateStatus=$state on current vuln-fix head" && close_count=$((close_count + 1))
      fi
      continue
    fi

    if [[ -n "$keep_head" && "$head" != "$keep_head" ]]; then
      close_vuln_deps_pr_with_supersede_comment "$name" "$pr_num" "superseded by $keep_head" && close_count=$((close_count + 1))
      continue
    fi

    heads+=("$head|$pr_num|$state")
  done < <(jq -c '.[]' <<< "$json")

  if [[ ${#heads[@]} -eq 0 ]]; then
    return 0
  fi

  newest_head=""
  newest_date=""
  for entry in "${heads[@]}"; do
    IFS='|' read -r head pr_num state <<< "$entry"
    head_date="$(vuln_deps_head_date_suffix "$head")"
    if [[ -z "$newest_date" || ( -n "$head_date" && "$head_date" > "$newest_date" ) ]]; then
      newest_date="$head_date"
      newest_head="$head"
    fi
  done

  for entry in "${heads[@]}"; do
    IFS='|' read -r head pr_num state <<< "$entry"
    if [[ -n "$newest_head" && "$head" != "$newest_head" ]]; then
      close_vuln_deps_pr_with_supersede_comment "$name" "$pr_num" "superseded by newer head $newest_head" && close_count=$((close_count + 1))
      continue
    fi
    if [[ "$state" == "DIRTY" || "$state" == "BEHIND" ]]; then
      close_vuln_deps_pr_with_supersede_comment "$name" "$pr_num" "mergeStateStatus=$state" && close_count=$((close_count + 1))
    fi
  done

  if [[ "$close_count" -gt 0 ]]; then
    echo "SUPERSEDE_SUMMARY $name: closed=$close_count keep_head=${keep_head:-$newest_head}" >&2
  fi
}

run_close_superseded_remote() {
  ensure_gh_git_auth

  if [[ -n "$SINGLE_REPO" ]]; then
    close_superseded_vuln_deps_prs_for_repo "$SINGLE_REPO" ""
    return 0
  fi

  for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
    is_excluded "$name" && continue
    close_superseded_vuln_deps_prs_for_repo "$name" ""
  done
  echo "remote close-superseded: scanned repos (Gate N1)"
  return 0
}

# --- PR body -------------------------------------------------------------------

format_finding_md() {
  local pkg section cur target ids
  IFS='|' read -r pkg section cur target ids <<< "$1"
  echo "  - \`$pkg\` ($section): $cur → **$target** ($ids)"
}

pr_body() {
  local repo_dir="$1"
  local osv_json="$2"
  local lock_result="$3"
  local smoke_result="$4"
  local findings_md="" unfix_line unfix_md=""
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    findings_md+="$(format_finding_md "$line")
"
  done < <(list_findings_for_repo "$repo_dir" "$osv_json")
  while IFS= read -r unfix_line; do
    [[ -z "$unfix_line" ]] && continue
    unfix_md+="  - \`$(echo "$unfix_line" | cut -d'|' -f1)\`: 无已发布修复版本（$(echo "$unfix_line" | cut -d'|' -f3)）
"
  done < <(list_unfixable_for_repo "$repo_dir" "$osv_json")
  [[ -z "$findings_md" ]] && findings_md="  (none)"
  if [[ -n "$unfix_md" ]]; then
    unfix_md=$'\n## 无修复版本的漏洞\n'"${unfix_md}"
  fi
  cat <<EOF
## Summary
- OSV 扫描发现已知漏洞的 npm 依赖，升到 **最低修复版本**（直接依赖精确 pin；传递依赖经 \`overrides\` pin）
- Lockfile 刷新: **${lock_result}**
- 开 PR 前 smoke（\`npm ci\` + 仓内 check/test/lint）: **${smoke_result}**

## 修复项
${findings_md}
${unfix_md}
## 合并后验证
- [ ] \`npm run check && npm test\` 已通过 CI
- [ ] 确认漏洞已消除（重跑 vuln-scan 或 \`osv-scanner\`）

## Deploy
merge → Release PR → \`master\` → CF Builds 自动 deploy（Agent 不代为 deploy）

---
Automation: workers-world/worker-support-action（OSV-Scanner weekly vuln scan）
EOF
}

# --- apply / check --------------------------------------------------------------

open_remote_pr() {
  local name="$1"
  local repo_dir="$2"
  local branch bump_branch pr_url n today
  local lock_result="skipped" smoke_result="skipped"
  local lock_log smoke_log osv_json
  lock_log="$(mktemp)"
  smoke_log="$(mktemp)"
  osv_json="$(mktemp)"
  if ! scan_repo_osv "$repo_dir" "$osv_json"; then
    echo "SKIP $name: osv 扫描失败或无 npm lockfile（v1 范围：根 npm lock）" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 1
  fi
  n="$(count_findings "$repo_dir" "$osv_json")"
  if [[ "$n" -eq 0 ]]; then
    echo "SKIP $name: 无可修复的漏洞依赖" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 1
  fi
  if repo_is_archived "$name"; then
    echo "SKIP $name: archived 仓库无法开 PR" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "DRY-RUN $repo_dir: $line" >&2
    done < <(list_findings_for_repo "$repo_dir" "$osv_json")
    echo "DRY-RUN PR workers-world/$name ($n packages)" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "SKIP $name: 需要 gh CLI" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 1
  fi
  branch="$(resolve_release_branch "$repo_dir")" || {
    echo "SKIP $name: 无法解析 dev 分支" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 1
  }
  today="$(date -u +%Y-%m-%d)"
  bump_branch="chore/fix-vulnerable-deps-${today}"
  git -C "$repo_dir" fetch origin "$branch" --quiet
  git -C "$repo_dir" checkout -B "$bump_branch" "origin/$branch" --quiet

  node "$VULN_LIB_MJS" apply-fixes "$repo_dir" "$osv_json" >&2
  if ! update_lockfile "$repo_dir" "$lock_log"; then
    echo "BLOCK $name: lockfile 刷新失败，不建 PR" >&2
    tail -20 "$lock_log" >&2 || true
    reset_repo_branch "$repo_dir" "$branch" "$bump_branch"
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    echo "BLOCK_REASON $name|lockfile_failed" >&2
    return 4
  fi
  lock_result="ok"

  if ! run_pre_pr_smoke "$repo_dir" "$smoke_log"; then
    echo "BLOCK $name: pre-PR smoke 失败，不建 PR" >&2
    tail -30 "$smoke_log" >&2 || true
    reset_repo_branch "$repo_dir" "$branch" "$bump_branch"
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    echo "BLOCK_REASON $name|smoke_failed" >&2
    return 4
  fi
  smoke_result="ok"

  git -C "$repo_dir" add package.json
  [[ -f "$repo_dir/package-lock.json" ]] && git -C "$repo_dir" add package-lock.json
  [[ -f "$repo_dir/npm-shrinkwrap.json" ]] && git -C "$repo_dir" add npm-shrinkwrap.json
  if git -C "$repo_dir" diff --staged --quiet; then
    echo "FAIL $name: 修复后无 staged 变更" >&2
    reset_repo_branch "$repo_dir" "$branch" "$bump_branch"
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 2
  fi
  if ! git -C "$repo_dir" commit -m "$VULN_DEPS_PR_TITLE" --quiet; then
    echo "FAIL $name: commit 失败" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 2
  fi
  if ! git -C "$repo_dir" push -u origin "$bump_branch" 2>&1; then
    echo "FAIL $name: push 失败" >&2
    rm -f "$lock_log" "$smoke_log" "$osv_json"
    return 2
  fi
  close_superseded_vuln_deps_prs_for_repo "$name" "$bump_branch"

  pr_url="$(gh pr create \
    --repo "workers-world/$name" \
    --base "$branch" \
    --head "$bump_branch" \
    --title "$VULN_DEPS_PR_TITLE" \
    --body "$(pr_body "$repo_dir" "$osv_json" "$lock_result" "$smoke_result")")"
  echo "PR $name: $pr_url" >&2
  if [[ "$AUTO_MERGE" -eq 1 ]]; then
    gate_n1_enable_automerge "$name" "$pr_url"
  else
    echo "GATE_N1 $name: --auto-merge 未开启，PR 等人工审" >&2
  fi
  printf 'PR_URL:%s\n' "$pr_url"
  rm -f "$lock_log" "$smoke_log" "$osv_json"
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
    if [[ "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
      gh issue create \
        --repo "$ISSUE_REPO" \
        --title "bump-vulnerable-npm-deps: ${block_count} 仓被 lock/smoke 闸阻断" \
        --body "下列仓存在漏洞依赖但未开修复 PR，请查看 [最近一次 workflow 日志](https://github.com/${ISSUE_REPO}/actions/workflows/vuln-scan.yml)。

$(printf '%s\n' "${blocked_lines[@]}")" \
        >/dev/null
      echo "blocked summary issue created"
    fi
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    run_close_superseded_remote || true
  fi
  cleanup_workdir "$workdir"
  if [[ "$fail_count" -gt 0 ]]; then
    return 1
  fi
  return 0
}

run_check_remote() {
  local workdir="" vuln_count=0 repo_count=0 unfixable_count=0
  local -a vuln_lines=()
  local osv_json line
  workdir="$(mktemp -d)"
  trap "cleanup_workdir '${workdir}'" RETURN

  ensure_gh_git_auth

  for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
    is_excluded "$name" && continue
    clone_org_repo "$name" "$workdir/$name" shallow 2>/dev/null || {
      echo "SKIP $name: clone failed"
      continue
    }
    [[ ! -f "$workdir/$name/package.json" ]] && continue
    repo_count=$((repo_count + 1))
    osv_json="$(mktemp)"
    if ! scan_repo_osv "$workdir/$name" "$osv_json"; then
      rm -f "$osv_json"
      continue
    fi
    if [[ "$(count_findings "$workdir/$name" "$osv_json")" -eq 0 ]] && [[ -z "$(list_unfixable_for_repo "$workdir/$name" "$osv_json")" ]]; then
      rm -f "$osv_json"
      continue
    fi
    vuln_count=$((vuln_count + 1))
    vuln_lines+=("- \`$name\`")
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      vuln_lines+=("  - $(echo "$line" | cut -d'|' -f1): $(echo "$line" | cut -d'|' -f3) → $(echo "$line" | cut -d'|' -f4) ($(echo "$line" | cut -d'|' -f5))")
    done < <(list_findings_for_repo "$workdir/$name" "$osv_json")
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      unfixable_count=$((unfixable_count + 1))
      vuln_lines+=("  - $(echo "$line" | cut -d'|' -f1): 无修复版本 ($(echo "$line" | cut -d'|' -f2,3))")
    done < <(list_unfixable_for_repo "$workdir/$name" "$osv_json")
    rm -f "$osv_json"
  done

  echo "remote check: $repo_count repos scanned, $vuln_count repos with vulnerable deps, $unfixable_count unfixable findings"
  if [[ ${#vuln_lines[@]} -gt 0 ]]; then
    printf '%s\n' "${vuln_lines[@]}"
  fi
  if [[ "$CREATE_ISSUE" -eq 1 && "$vuln_count" -gt 0 && "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create \
      --repo "$ISSUE_REPO" \
      --title "npm 依赖 CVE 漏洞（OSV）：${vuln_count} 个仓" \
      --body "修复：\`workflow_dispatch\` 触发 [vuln-scan.yml](https://github.com/${ISSUE_REPO}/actions/workflows/vuln-scan.yml)，或 \`vuln-scan/bump-vulnerable-npm-deps.sh --remote --apply\`。

发现清单：
$(printf '%s\n' "${vuln_lines[@]}")" \
      >/dev/null
    echo "issue created (remote vulnerable deps)"
  fi
  cleanup_workdir "$workdir"
  [[ "$vuln_count" -eq 0 ]]
}

main() {
  echo "mode=$MODE remote=$REMOTE dry_run=$DRY_RUN create_issue=$CREATE_ISSUE auto_merge=$AUTO_MERGE close_superseded=$CLOSE_SUPERSEDED scanner=$OSV_SCANNER_BIN"
  if [[ "$CLOSE_SUPERSEDED" -eq 1 ]]; then
    run_close_superseded_remote
    exit $?
  fi
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
