#!/usr/bin/env bash
# 远程防漂移检查：clone workers-world org 下全部 Worker 仓，与 meta 仓 templates/worker/ canonical 对比。
# 本地日常检查用 sync-worker-configs.sh --check（共置目录，无需 clone）。
# 漂移仓输出表格，并在 meta 仓开 issue 报告。CI 或本地均可运行（需 gh 与网络）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_ROOT="${TEMPLATES_ROOT:-$REPO_ROOT/templates}"
ISSUE_REPO="${ISSUE_REPO:-workers-world/worker-support-action}"
TPL="$TEMPLATES_ROOT/worker"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 与本地 sync 脚本一致的排除清单
EXCLUDE=(cloudflare-os docs-site r2-image-transform-worker aws_hub_to_r2_worker cloudflare-docs framework_sdk_worker)

DRIFT_REPORT=""
REPO_COUNT=0
DRIFT_COUNT=0

for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
  skip=0
  for e in "${EXCLUDE[@]}"; do
    [[ "$name" == "$e" ]] && skip=1
  done
  [[ $skip -eq 1 ]] && continue

  git clone --depth 1 --quiet "https://github.com/workers-world/$name.git" "$WORKDIR/$name" 2>/dev/null || {
    echo "SKIP $name: clone failed"
    continue
  }
  REPO_COUNT=$((REPO_COUNT + 1))
  [[ ! -f "$WORKDIR/$name/package.json" ]] && continue

  issues=""
  [[ ! -f "$WORKDIR/$name/biome.json" ]] && issues="缺 biome.json"
  if [[ ! -f "$WORKDIR/$name/biome-shared.json" ]]; then
    issues="${issues:+$issues、}缺 biome-shared.json"
  elif ! cmp -s "$TPL/biome-shared.json" "$WORKDIR/$name/biome-shared.json"; then
    issues="${issues:+$issues、}biome-shared 漂移"
  fi
  if [[ -f "$WORKDIR/$name/.npmrc" ]] && { ! grep -qF '@workers-world:registry=https://npm.pkg.github.com' "$WORKDIR/$name/.npmrc" || ! grep -qF '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' "$WORKDIR/$name/.npmrc"; }; then
    issues="${issues:+$issues、}.npmrc 漂移"
  fi
  if [[ -f "$WORKDIR/$name/.github/workflows/ci.yml" ]] && [[ -f "$TEMPLATES_ROOT/github/sync-worker-github-configs.py" ]]; then
    if ! python3 "$TEMPLATES_ROOT/github/sync-worker-github-configs.py" --check-one "$WORKDIR/$name" "$name" 2>/dev/null; then
      issues="${issues:+$issues、}.github 漂移"
    fi
  fi

  if [[ -n "$issues" ]]; then
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    DRIFT_REPORT="${DRIFT_REPORT}- \`$name\`: $issues"$'\n'
    echo "DRIFT: $name → $issues"
  fi
done

echo "checked $REPO_COUNT repos, $DRIFT_COUNT drifted"

if [[ $DRIFT_COUNT -gt 0 ]] && [[ "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
  gh issue create \
    --repo "$ISSUE_REPO" \
    --title "配置漂移：$DRIFT_COUNT 个仓偏离 templates/worker canonical" \
    --body "本地修复（meta 仓）：\`./sync-worker-configs.sh\`（biome/npmrc）与 \`./sync-worker-github-configs.sh\`（.github）后各仓提交。

漂移清单：

$DRIFT_REPORT" \
    >/dev/null
  echo "issue created"
fi
