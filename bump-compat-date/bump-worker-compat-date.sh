#!/usr/bin/env bash
# 批量抬升 Worker wrangler 配置中的 compatibility_date。
# 用法：
#   ./bump-worker-compat-date.sh --check [--max-age-days N]
#   ./bump-worker-compat-date.sh --apply [--date YYYY-MM-DD] [--dry-run]
#   ./bump-worker-compat-date.sh --remote --apply [--date YYYY-MM-DD] [--dry-run]
#   ./bump-worker-compat-date.sh --remote --apply --repo mok1 [--dry-run]
# 环境：--remote 开 PR 需 gh + GH_TOKEN（PAT repo）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$REPO_ROOT}"
# shellcheck source=../release/resolve-release-branch.sh
source "$REPO_ROOT/release/resolve-release-branch.sh"
TEMPLATES_ROOT="${TEMPLATES_ROOT:-$REPO_ROOT/templates}"
ISSUE_REPO="${ISSUE_REPO:-workers-world/worker-support-action}"
TPL_WRANGLER="$TEMPLATES_ROOT/worker/wrangler.example.toml"
OVERRIDES_FILE="$TEMPLATES_ROOT/github/worker-ci-overrides.yaml"

EXCLUDE=(cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs framework_sdk_worker)
LOCAL_EXCLUDE=(templates framework_sdk_worker cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs)

MODE="check"
REMOTE=0
DRY_RUN=0
MAX_AGE_DAYS=30
TARGET_DATE=""
MIN_DATE="2026-05-01"
INCLUDE_DOCS_SITE=0
SINGLE_REPO=""
CREATE_ISSUE=0

usage() {
  cat <<'EOF'
用法:
  ./bump-worker-compat-date.sh --check [--max-age-days N] [--create-issue]
  ./bump-worker-compat-date.sh --apply [--date YYYY-MM-DD] [--dry-run]
  ./bump-worker-compat-date.sh --remote --apply [--date YYYY-MM-DD] [--repo NAME] [--dry-run]

选项:
  --check              列出 compatibility_date 早于阈值的仓（默认 30 天前）
  --apply              改写 wrangler.toml / wrangler.jsonc（只抬升不降低）
  --remote             遍历 workers-world org（clone + 开 PR）
  --date YYYY-MM-DD    目标日期（默认今天 UTC）
  --max-age-days N     --check 时过期阈值（默认 30）
  --min-date YYYY-MM-DD  全局最低日期（默认 2026-05-01）
  --include docs-site  纳入 docs-site（默认排除）
  --repo NAME          --remote 时只处理单个仓
  --create-issue       --check 且有过期仓时在 ISSUE_REPO 开 issue（默认本仓）
  --dry-run            只打印将改动的文件
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --remote) REMOTE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --create-issue) CREATE_ISSUE=1; shift ;;
    --include)
      [[ "${2:-}" == "docs-site" ]] || { echo "--include 目前仅支持 docs-site" >&2; exit 1; }
      INCLUDE_DOCS_SITE=1
      shift 2
      ;;
    --max-age-days)
      MAX_AGE_DAYS="${2:?}"
      shift 2
      ;;
    --min-date)
      MIN_DATE="${2:?}"
      shift 2
      ;;
    --date)
      TARGET_DATE="${2:?}"
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
  : # local apply ok
elif [[ "$MODE" == "apply" && "$REMOTE" -eq 1 ]]; then
  : # remote apply ok
elif [[ "$MODE" == "check" ]]; then
  :
else
  echo "无效组合：--apply 需单独使用；--remote 仅与 --apply 联用" >&2
  usage
  exit 1
fi

if [[ -z "$TARGET_DATE" ]]; then
  TARGET_DATE="$(date -u +%Y-%m-%d)"
fi

if ! [[ "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "无效 --date: $TARGET_DATE" >&2
  exit 1
fi

days_ago() {
  local days="$1"
  if date -u -v-"${days}"d +%Y-%m-%d >/dev/null 2>&1; then
    date -u -v-"${days}"d +%Y-%m-%d
  else
    date -u -d "${days} days ago" +%Y-%m-%d
  fi
}

date_max() {
  local a="$1" b="$2"
  if [[ "$a" > "$b" ]]; then
    echo "$a"
  else
    echo "$b"
  fi
}

is_excluded() {
  local name="$1"
  local e
  for e in "${EXCLUDE[@]}"; do
    [[ "$name" == "$e" ]] && return 0
  done
  if [[ "$name" == "docs-site" && "$INCLUDE_DOCS_SITE" -eq 0 ]]; then
    return 0
  fi
  return 1
}

is_local_excluded() {
  local name="$1"
  local e
  for e in "${LOCAL_EXCLUDE[@]}"; do
    [[ "$name" == "$e" ]] && return 0
  done
  if [[ "$name" == "docs-site" && "$INCLUDE_DOCS_SITE" -eq 0 ]]; then
    return 0
  fi
  return 1
}

worker_min_date() {
  local worker="$1"
  local line min
  if [[ -f "$OVERRIDES_FILE" ]]; then
    line="$(awk -v w="$worker" '
      /^compat_min_dates:/ { in_block=1; next }
      in_block && /^[^[:space:]#]/ && $0 !~ /^  / { in_block=0 }
      in_block && $1 == w ":" { gsub(/"/, "", $2); print $2; exit }
    ' "$OVERRIDES_FILE")"
    if [[ -n "$line" ]]; then
      min="$line"
    else
      min="$MIN_DATE"
    fi
  else
    min="$MIN_DATE"
  fi
  date_max "$min" "$MIN_DATE"
}

find_wrangler_config() {
  local dir="${1%/}"
  if [[ -f "$dir/wrangler.toml" ]]; then
    echo "$dir/wrangler.toml"
  elif [[ -f "$dir/wrangler.jsonc" ]]; then
    echo "$dir/wrangler.jsonc"
  fi
}

read_compat_date() {
  local file="$1"
  local line
  line="$(grep -E '^[[:space:]]*compatibility_date[[:space:]]*=' "$file" 2>/dev/null | head -1 || true)"
  if [[ -z "$line" && "$file" == *.jsonc ]]; then
    line="$(grep -E '"compatibility_date"[[:space:]]*:' "$file" 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$line" ]]; then
    return 1
  fi
  echo "$line" | sed -E 's/.*["'\'']([0-9]{4}-[0-9]{2}-[0-9]{2})["'\''].*/\1/'
}

effective_target_date() {
  local worker="$1"
  local min_for_worker
  min_for_worker="$(worker_min_date "$worker")"
  date_max "$TARGET_DATE" "$min_for_worker"
}

# 改写文件中的 compatibility_date；有变更返回 0，skip 返回 1
bump_wrangler_file() {
  local file="$1"
  local worker="$2"
  local current new_date eff
  current="$(read_compat_date "$file" || true)"
  eff="$(effective_target_date "$worker")"
  if [[ -z "$current" ]]; then
    echo "SKIP $file: 无 compatibility_date" >&2
    return 1
  fi
  if [[ "$current" > "$eff" ]] || [[ "$current" == "$eff" ]]; then
    echo "SKIP $file: $current 已 >= $eff" >&2
    return 1
  fi
  new_date="$eff"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN $file: $current -> $new_date" >&2
    return 0
  fi
  if [[ "$file" == *.toml ]]; then
    sed -i.bak -E "s/^([[:space:]]*compatibility_date[[:space:]]*=[[:space:]]*)\"[0-9]{4}-[0-9]{2}-[0-9]{2}\"/\1\"$new_date\"/" "$file"
  else
    sed -i.bak -E "s/(\"compatibility_date\"[[:space:]]*:[[:space:]]*)\"[0-9]{4}-[0-9]{2}-[0-9]{2}\"/\1\"$new_date\"/" "$file"
  fi
  rm -f "${file}.bak"
  echo "BUMP $file: $current -> $new_date" >&2
  return 0
}

check_worker_dir() {
  local dir="$1"
  local name="$2"
  local file current threshold eff stale=0
  threshold="$(days_ago "$MAX_AGE_DAYS")"
  file="$(find_wrangler_config "$dir" || true)"
  if [[ -z "$file" ]]; then
    return 0
  fi
  current="$(read_compat_date "$file" || true)"
  if [[ -z "$current" ]]; then
    echo "STALE $name: 缺少 compatibility_date ($file)"
    return 1
  fi
  eff="$(effective_target_date "$name")"
  if [[ "$current" < "$threshold" ]]; then
    echo "STALE $name: $current < $threshold (file: ${file#"$WORKSPACE_ROOT"/})"
    stale=1
  fi
  if [[ "$current" < "$eff" && "$MODE" == "check" ]]; then
    echo "BELOW_TARGET $name: $current < 建议 $eff"
  fi
  return "$stale"
}

apply_local() {
  local dir w file
  for dir in "$WORKSPACE_ROOT"/*/; do
    w="$(basename "$dir")"
    is_local_excluded "$w" && continue
    [[ ! -f "$dir/package.json" ]] && continue
    file="$(find_wrangler_config "$dir" || true)"
    [[ -z "$file" ]] && continue
    bump_wrangler_file "$file" "$w" || true
  done
  if [[ -f "$TPL_WRANGLER" ]]; then
    bump_wrangler_file "$TPL_WRANGLER" "__WORKER_NAME__" || true
  fi
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
  local dir="$1"
  rm -rf "$dir"
  trap - RETURN
}

pr_body() {
  local new_date="$1"
  cat <<EOF
## Summary
- 将 \`compatibility_date\` 抬升至 \`$new_date\`（Cloudflare [Best Practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/) 建议定期更新）
- 未改动 \`compatibility_flags\`

## 合并后验证
- [ ] \`npm run check && npm test\` 已通过 CI
- [ ] cron / Queue Worker：观察首个周期是否正常（如 \`gold-price-worker\`）
- [ ] 含 Browser / Cache / Containers 绑定的 Worker：确认无 runtime 回归

## Deploy
merge → Release PR → \`master\` → CF Builds 自动 deploy（Agent 不代为 deploy）
EOF
}

open_remote_pr() {
  local name="$1"
  local repo_dir="$2"
  local file branch bump_branch eff new_date pr_url current
  file="$(find_wrangler_config "$repo_dir" || true)"
  if [[ -z "$file" ]]; then
    echo "SKIP $name: 无 wrangler 配置" >&2
    return 1
  fi
  eff="$(effective_target_date "$name")"
  current="$(read_compat_date "$file" || true)"
  if [[ -z "$current" ]] || [[ "$current" > "$eff" ]] || [[ "$current" == "$eff" ]]; then
    echo "SKIP $name: ${current:-<missing>} 已 >= $eff" >&2
    return 1
  fi
  new_date="$eff"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN PR workers-world/$name: $current -> $new_date" >&2
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
  bump_branch="chore/bump-compat-date-${new_date}"
  git -C "$repo_dir" fetch origin "$branch" --quiet
  git -C "$repo_dir" checkout -B "$bump_branch" "origin/$branch" --quiet
  bump_wrangler_file "$file" "$name"
  git -C "$repo_dir" add "$file"
  git -C "$repo_dir" commit -m "chore: bump compatibility_date 至 ${new_date}" --quiet
  git -C "$repo_dir" push -u origin "$bump_branch" --quiet
  pr_url="$(gh pr create \
    --repo "workers-world/$name" \
    --base "$branch" \
    --head "$bump_branch" \
    --title "chore: bump compatibility_date 至 ${new_date}" \
    --body "$(pr_body "$new_date")")"
  echo "PR $name: $pr_url" >&2
  echo "$pr_url"
}

run_remote() {
  local workdir pr_count=0 skip_count=0 fail_count=0
  local name pr_line
  local -a pr_urls=()
  workdir="$(mktemp -d)"
  trap 'cleanup_workdir "$workdir"' RETURN

  ensure_gh_git_auth
  ensure_git_identity

  if [[ -n "$SINGLE_REPO" ]]; then
    clone_org_repo "$SINGLE_REPO" "$workdir/$SINGLE_REPO"
    pr_line="$(open_remote_pr "$SINGLE_REPO" "$workdir/$SINGLE_REPO" || true)"
    if [[ "$pr_line" == http* ]]; then
      pr_urls+=("$pr_line")
      pr_count=$((pr_count + 1))
    fi
    printf 'remote summary: pr=%s skip/fail=%s\n' "$pr_count" "$((skip_count + fail_count))"
    cleanup_workdir "$workdir"
    return 0
  fi

  for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
    is_excluded "$name" && continue
    if ! clone_org_repo "$name" "$workdir/$name" 2>/dev/null; then
      echo "FAIL $name: clone failed"
      fail_count=$((fail_count + 1))
      continue
    fi
    [[ ! -f "$workdir/$name/package.json" ]] && continue
    pr_line="$(open_remote_pr "$name" "$workdir/$name" || true)"
    if [[ "$pr_line" == http* ]]; then
      pr_urls+=("$pr_line")
      pr_count=$((pr_count + 1))
    elif [[ "$pr_line" == SKIP* ]]; then
      skip_count=$((skip_count + 1))
    fi
  done

  echo "remote summary: pr=$pr_count checked repos with skip/fail=$skip_count/$fail_count"
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

run_check_local() {
  local stale_count=0
  local dir w threshold
  local -a stale_lines=()
  threshold="$(days_ago "$MAX_AGE_DAYS")"
  for dir in "$WORKSPACE_ROOT"/*/; do
    w="$(basename "$dir")"
    is_local_excluded "$w" && continue
    [[ ! -f "$dir/package.json" ]] && continue
    if check_worker_dir "$dir" "$w"; then
      stale_count=$((stale_count + 1))
      local current
      current="$(read_compat_date "$(find_wrangler_config "$dir")" 2>/dev/null || echo "?")"
      stale_lines+=("- \`$w\` ($current)")
    fi
  done
  if [[ -f "$TPL_WRANGLER" ]]; then
    local tpl_current
    tpl_current="$(read_compat_date "$TPL_WRANGLER" || true)"
    if [[ -n "$tpl_current" && "$tpl_current" < "$threshold" ]]; then
      echo "STALE templates/worker/wrangler.example.toml: $tpl_current < $threshold"
      stale_count=$((stale_count + 1))
      stale_lines+=("- \`templates/worker/wrangler.example.toml\` ($tpl_current)")
    fi
  fi
  echo "local check: $stale_count stale (threshold=$threshold, max_age=${MAX_AGE_DAYS}d)"
  if [[ "$CREATE_ISSUE" -eq 1 && "$stale_count" -gt 0 && "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create \
      --repo "$ISSUE_REPO" \
      --title "compat_date 过期：${stale_count} 个本地路径" \
      --body "运行 \`bump-compat-date/bump-worker-compat-date.sh --apply\` 或 workflow_dispatch [bump-compat-date.yml](https://github.com/${ISSUE_REPO}/actions/workflows/bump-compat-date.yml)。

过期清单（本地共置）：
$(printf '%s\n' "${stale_lines[@]}")" \
      >/dev/null
    echo "issue created (local stale)"
  fi
  [[ "$stale_count" -eq 0 ]]
}

run_check_remote() {
  local workdir stale_count=0 repo_count=0
  local -a stale_lines=()
  workdir="$(mktemp -d)"
  trap 'cleanup_workdir "$workdir"' RETURN
  local threshold
  threshold="$(days_ago "$MAX_AGE_DAYS")"

  ensure_gh_git_auth
  ensure_git_identity

  for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
    is_excluded "$name" && continue
    clone_org_repo "$name" "$workdir/$name" shallow 2>/dev/null || {
      echo "SKIP $name: clone failed"
      continue
    }
    repo_count=$((repo_count + 1))
    [[ ! -f "$workdir/$name/package.json" ]] && continue
    if check_worker_dir "$workdir/$name" "$name"; then
      stale_count=$((stale_count + 1))
      local current
      current="$(read_compat_date "$(find_wrangler_config "$workdir/$name")")"
      stale_lines+=("- \`$name\`: $current")
    fi
  done

  echo "remote check: $repo_count repos, $stale_count stale (threshold=$threshold)"
  if [[ "$CREATE_ISSUE" -eq 1 && "$stale_count" -gt 0 && "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
    gh issue create \
      --repo "$ISSUE_REPO" \
      --title "compat_date 过期：${stale_count} 个仓" \
      --body "修复：\`workflow_dispatch\` 触发 [bump-compat-date.yml](https://github.com/${ISSUE_REPO}/actions/workflows/bump-compat-date.yml)，或 \`bump-compat-date/bump-worker-compat-date.sh --remote --apply\`。

过期清单：
$(printf '%s\n' "${stale_lines[@]}")" \
      >/dev/null
    echo "issue created (remote stale)"
  fi
  cleanup_workdir "$workdir"
  [[ "$stale_count" -eq 0 ]]
}

main() {
  echo "target_date=$TARGET_DATE min_date=$MIN_DATE mode=$MODE remote=$REMOTE dry_run=$DRY_RUN"
  if [[ "$MODE" == "apply" ]]; then
    if [[ "$REMOTE" -eq 1 ]]; then
      run_remote || exit $?
    else
      apply_local
      echo "local apply done"
    fi
    exit 0
  fi

  local ok=0
  if [[ "$REMOTE" -eq 1 ]]; then
    run_check_remote || ok=$?
  else
    run_check_local || ok=$?
  fi
  exit "$ok"
}

main
