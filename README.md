# worker-support-action

公开仓自跑 **workers-world org 运维** workflow，省 meta 仓 `cloudflare_work` Actions 额度：

| Workflow | 频率 | 作用 |
|----------|------|------|
| [bump-compat-date.yml](.github/workflows/bump-compat-date.yml) | 每月 1 日 | 批量抬升各 Worker `compatibility_date` 并开 PR |
| [bump-cloudflare-deps.yml](.github/workflows/bump-cloudflare-deps.yml) | 每周一 | 将 org 各仓 Cloudflare 相关 npm 依赖升至 `latest` 并开 PR（WW-49） |
| [config-drift.yml](.github/workflows/config-drift.yml) | 每周一 | biome/npmrc/.github 漂移 + compat 过期检测，本仓开 issue |
| [secret-scan.yml](.github/workflows/secret-scan.yml) | 每周二 | gitleaks 全历史扫描 **public** 仓，有发现时脱敏发信 + artifact |
| [clean-stale-pr-branches.yml](.github/workflows/clean-stale-pr-branches.yml) | 每周一 | 删除 org 已合并 + closed≥30d 未合并 PR head（WW-147；cron 默认 dry-run） |

Canonical 模板仍来自 [`workers-world/cloudflare_work`](https://github.com/workers-world/cloudflare_work) 的 `templates/`（drift/bump workflow 内 sparse checkout）。

## 目录（按能力）

| 目录 | 内容 |
|------|------|
| [bump-compat-date/](bump-compat-date/) | `compatibility_date` 批量升级 |
| [bump-cloudflare-dependencies/](bump-cloudflare-dependencies/) | Cloudflare npm 依赖升级 |
| [config-drift-check/](config-drift-check/) | 远程 org 配置漂移检查 |
| [secret-scan/](secret-scan/) | gitleaks org/单仓扫描 |
| [pr-branch-cleanup/](pr-branch-cleanup/) | 已合并/陈旧 PR 分支清理 |
| [release/](release/) | 发布轨分支解析（bump 脚本共用） |

## 环境

| 名称 | 说明 |
|------|------|
| `GHA_TOKEN` / `GITHUB_TOKEN` | `gh` CLI；org 扫描、clone、开 issue |
| `GHA_TOKEN`（**bump-cloudflare-deps 必填**） | 私有仓 clone、GitHub Packages（`NODE_AUTH_TOKEN`）、开 PR；不可用 `GITHUB_TOKEN` 替代 |
| `GHA_TOKEN`（**clean-stale-pr-branches 删分支**） | 读 PR/分支元数据并 `DELETE` ref；需 **Contents: Read and write**（classic `repo` 或等价 fine-grained） |
| Repo Variable `PR_BRANCH_CLEANUP_LIVE`（**仅本仓**） | 设为 `true` 时，**定时**任务才真正删分支；否则 cron 仍为 dry-run |
| `NOTIFY_WORKER_URL` | Org Variable |
| `NOTIFY_GHA_TOKEN` | 发信（notify-worker 默认收件人） |

## 脚本

| 脚本 | 说明 |
|------|------|
| [bump-worker-compat-date.sh](bump-compat-date/bump-worker-compat-date.sh) | `--check` / `--apply` / `--remote --apply` |
| [bump-cloudflare-npm-deps.sh](bump-cloudflare-dependencies/bump-cloudflare-npm-deps.sh) | `--check --remote` / `--remote --apply`；白名单 [cloudflare-npm-deps.allowlist](bump-cloudflare-dependencies/cloudflare-npm-deps.allowlist) |
| [check-config-drift-remote.sh](config-drift-check/check-config-drift-remote.sh) | 远程 org 漂移检查 |
| [scan-secrets.py](secret-scan/scan-secrets.py) | gitleaks org/单仓扫描（默认 public、全历史） |
| [clean-stale-pr-branches.py](pr-branch-cleanup/clean-stale-pr-branches.py) | 扫描 org 已合并 PR 残留 head；白名单 [pr-branch-cleanup.allowlist](pr-branch-cleanup/pr-branch-cleanup.allowlist) |

环境变量（drift/bump）：

- `TEMPLATES_ROOT` — 默认 `$REPO_ROOT/templates`；CI 指向 checkout 的 `cloudflare_work/templates`
- `WORKSPACE_ROOT` — 本地 `--apply`/`--check` 扫描根（默认仓库根；meta 仓可设为 `$PWD`）
- `ISSUE_REPO` — 默认 `workers-world/worker-support-action`

环境变量（secret scan）：

- `INPUT_ORG` / `INPUT_REPO` — org 全扫或单仓
- `INPUT_VISIBILITY` — 默认 `public`
- `INPUT_EXCLUDE_FILE` — 默认 `secret-scan/exclude-secrets.txt`（相对 cwd）或脚本同目录 `exclude-secrets.txt`
- `GITLEAKS_BIN` — 默认 `gitleaks`（workflow 安装到 `/usr/local/bin/gitleaks`）
- `INPUT_CREATE_ISSUE` — 有发现时在本仓开 issue（body 已脱敏）

产物：`secrets-scan.json`、`secrets-scan.md`（**不含** secret 原文）、`.scan-meta.json`。

## Secret scan 选型

| 工具 | v1 | 说明 |
|------|----|------|
| **Gitleaks CLI** | 已接入 | 离线、MIT；weekly org 巡检 |
| **TruffleHog verified** | v2 预留 | 仅对 gitleaks 命中仓复扫，降低误报 |
| **GitHub Secret Scanning** | org 侧建议开启 | push 实时拦，不替代历史扫 |

邮件/issue 正文**仅**含 repo、RuleID、文件、行号；完整 JSON 仅进 artifact。

## 本地调试

```bash
# 需已安装 gitleaks + gh auth
export GH_TOKEN=...
export INPUT_ORG=workers-world
export INPUT_REPO=orchestrator-worker   # 或留空扫 org
./secret-scan/scan-secrets.sh
cat secrets-scan.md .scan-meta.json
```

## meta 仓本地用法（drift/bump）

在 `cloudflare_work/` 根目录：

```bash
export TEMPLATES_ROOT="$PWD/templates"
export WORKSPACE_ROOT="$PWD"
bash path/to/worker-support-action/bump-compat-date/bump-worker-compat-date.sh --apply
bash path/to/worker-support-action/bump-compat-date/bump-worker-compat-date.sh --check --remote
```

## 发版

`dev_*` → Validate → Promote → `master` → 打 `v*` tag（见 [gh-release-on-tag.yml](.github/workflows/gh-release-on-tag.yml)）。

文档权威副本：[workers-world-dot-github/docs/worker-compat-date.md](../workers-world-dot-github/docs/worker-compat-date.md)（meta 仓内路径）。
