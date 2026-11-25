#!/usr/bin/env bash
# 远程防漂移检查：clone workers-world org 下全部 Worker 仓，与 meta 仓 templates/worker/ canonical 对比。
# 本地日常检查用 sync-worker-configs.sh --check（共置目录，无需 clone）。
# 漂移仓输出表格，并在 meta 仓开 issue 报告。CI 或本地均可运行（需 gh 与网络）。
#
# 基线纪律（GitOps 模型）：
#   - 报告是「as-of」一次性视图，修复前必须重新运行本检查，勿按 issue 清单盲修
#   - 仓身份由各仓 .ww-repo.json 的 type 声明（契约：framework_sdk_worker/meta/repo-meta）；
#     type ∈ {sdk, action, tool, app} 的仓 .github 自治，不做 worker 模板比对
#     （曾致 java-actions/container-actions 等被误报 .github 漂移）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_ROOT="${TEMPLATES_ROOT:-$REPO_ROOT/templates}"
ISSUE_REPO="${ISSUE_REPO:-workers-world/worker-support-action}"
TPL="$TEMPLATES_ROOT/worker"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
AS_OF="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 参与范围派生（勿写死仓单）：一律走 repo-meta CLI 门面（快照由 `ww wt deps --sync`
# 生成到 templates/github/repo-meta/，随本仓 templates sparse-checkout 下发）。
# worker 配置检查：participates config；.github 检查：GITHUB_SELF_GOVERNED_TYPES + python --check-one 双闸。
GITHUB_SELF_GOVERNED_TYPES="sdk action tool app"
META_CLI="$TEMPLATES_ROOT/github/repo-meta/repo-meta-cli.mjs"
[[ -f "$META_CLI" ]] || { echo "missing $META_CLI（先跑 ww wt deps --sync 生成快照）" >&2; exit 1; }

DRIFT_REPORT=""
WARN_REPORT=""
REPO_COUNT=0
DRIFT_COUNT=0

for name in $(gh repo list workers-world --json name --jq '.[].name' --limit 200); do
  git clone --depth 1 --quiet "https://github.com/workers-world/$name.git" "$WORKDIR/$name" 2>/dev/null || {
    echo "SKIP $name: clone failed"
    continue
  }
  REPO_COUNT=$((REPO_COUNT + 1))
  [[ ! -f "$WORKDIR/$name/package.json" ]] && continue

  # 仓身份（未声明 = WARN + 跳过；非法 = META-ERROR 记 FAIL）
  repo_meta_rc=0
  repo_type="$(node "$META_CLI" get "$WORKDIR/$name" 2>/dev/null)" || repo_meta_rc=$?
  if [[ $repo_meta_rc -eq 2 ]]; then
    echo "META-ERROR $name: $(node "$META_CLI" get "$WORKDIR/$name" 2>&1 >/dev/null | head -1)"
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    DRIFT_REPORT="${DRIFT_REPORT}- \`$name\`: .ww-repo.json 非法（修复后再跑）"$'\n'
    continue
  fi
  if [[ "$repo_type" == "null" ]]; then
    WARN_REPORT="${WARN_REPORT}- \`$name\`: 缺 .ww-repo.json（建议声明仓身份，见 framework_sdk_worker/meta/repo-meta）"$'\n'
    continue
  fi
  repo_type="$(node -e "const m=JSON.parse(process.argv[1]);console.log(m.type??'')" "$repo_type")"

  # worker 配置检查：participates config（type: worker 且 pipes.config 未退出）
  if ! node "$META_CLI" participates config "$WORKDIR/$name" 2>/dev/null; then
    continue
  fi

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
  # .github 比对：worker 类型（或未声明）才套标准模板；自治类型跳过
  github_check=0
  case " $GITHUB_SELF_GOVERNED_TYPES " in
    *" $repo_type "*) github_check=0 ;;
    *) github_check=1 ;;
  esac
  if [[ $github_check -eq 1 ]] && [[ -f "$WORKDIR/$name/.github/workflows/ci.yml" ]] && [[ -f "$TEMPLATES_ROOT/github/sync-worker-github-configs.py" ]]; then
    if ! python3 "$TEMPLATES_ROOT/github/sync-worker-github-configs.py" --check-one "$WORKDIR/$name" "$name" 2>/dev/null; then
      issues="${issues:+$issues、}.github 漂移"
    fi
  fi

  if [[ -n "$issues" ]]; then
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    DRIFT_REPORT="${DRIFT_REPORT}- \`$name\`（type=${repo_type:-未声明}）: $issues"$'\n'
    echo "DRIFT: $name（type=${repo_type:-未声明}） → $issues"
  fi
done

echo "checked $REPO_COUNT repos, $DRIFT_COUNT drifted (as-of $AS_OF)"

if [[ $DRIFT_COUNT -gt 0 ]] && [[ "${GH_TOKEN:-}" != "" ]] && command -v gh >/dev/null 2>&1; then
  gh issue create \
    --repo "$ISSUE_REPO" \
    --title "配置漂移：$DRIFT_COUNT 个仓偏离 templates/worker canonical" \
    --body "本地修复（meta 仓）：\`./sync-worker-configs.sh\`（biome/npmrc）与 \`./sync-worker-github-configs.sh\`（.github）后各仓提交。

> ⚠️ 修复前先重跑本检查——本报告是 as-of 快照，清单可能已过时。
> 基线：templates/worker canonical（.github 基线见 sync-worker-github-configs.py 内的 bundle tag）。

as-of：$AS_OF

漂移清单：

$DRIFT_REPORT" \
    >/dev/null
  echo "issue created"
fi
