# worker-support-action

公开仓自跑 **workers-world org 运维** workflow，省 meta 仓 `cloudflare_work` Actions 额度：

| Workflow | 频率 | 作用 |
|----------|------|------|
| [bump-compat-date.yml](.github/workflows/bump-compat-date.yml) | 每月 1 日 | 批量抬升各 Worker `compatibility_date` 并开 PR |
| [bump-cloudflare-deps.yml](.github/workflows/bump-cloudflare-deps.yml) | 每周一 | 将 org 各仓 Cloudflare 相关 npm 依赖升至 `latest` 并开 PR（WW-49） |
| [config-drift.yml](.github/workflows/config-drift.yml) | 每周一 | biome/npmrc/.github 漂移 + compat 过期检测，本仓开 issue |
| [secret-scan.yml](.github/workflows/secret-scan.yml) | 每周二 | gitleaks 全历史扫描 **public** 仓，有发现时脱敏发信 + artifact |

Canonical 模板仍来自 [`workers-world/cloudflare_work`](https://github.com/workers-world/cloudflare_work) 的 `templates/`（drift/bump workflow 内 sparse checkout）。

## 环境

| 名称 | 说明 |
|------|------|
| `GHA_TOKEN` / `GITHUB_TOKEN` | `gh` CLI；org 扫描、clone、开 issue |
| `GHA_TOKEN`（**bump-cloudflare-deps 必填**） | 私有仓 clone、GitHub Packages（`NODE_AUTH_TOKEN`）、开 PR；不可用 `GITHUB_TOKEN` 替代 |
| `NOTIFY_WORKER_URL` | Org Variable |
| `NOTIFY_GHA_TOKEN` | 发信（notify-worker 默认收件人） |

## 脚本

| 脚本 | 说明 |
|------|------|
| [bump-worker-compat-date.sh](bump-worker-compat-date.sh) | `--check` / `--apply` / `--remote --apply` |
| [bump-cloudflare-npm-deps.sh](bump-cloudflare-npm-deps.sh) | `--check --remote` / `--remote --apply`；白名单 [cloudflare-npm-deps.allowlist](cloudflare-npm-deps.allowlist) |
| [check-config-drift-remote.sh](check-config-drift-remote.sh) | 远程 org 漂移检查 |
| [scan-secrets.py](scan-secrets.py) | gitleaks org/单仓扫描（默认 public、全历史） |

环境变量（drift/bump）：

- `TEMPLATES_ROOT` — 默认 `$ROOT/templates`；CI 指向 checkout 的 `cloudflare_work/templates`
- `ISSUE_REPO` — 默认 `workers-world/worker-support-action`

环境变量（secret scan）：

- `INPUT_ORG` / `INPUT_REPO` — org 全扫或单仓
- `INPUT_VISIBILITY` — 默认 `public`
- `INPUT_EXCLUDE_FILE` — 默认 `exclude-secrets.txt`
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
./scan-secrets.sh
cat secrets-scan.md .scan-meta.json
```

## meta 仓本地用法（drift/bump）

在 `cloudflare_work/` 根目录：

```bash
export TEMPLATES_ROOT="$PWD/templates"
export ROOT="$PWD"
bash path/to/worker-support-action/bump-worker-compat-date.sh --apply
bash path/to/worker-support-action/bump-worker-compat-date.sh --check --remote
```

## 发版

`dev_*` → Validate → Promote → `master` → 打 `v*` tag（见 [gh-release-on-tag.yml](.github/workflows/gh-release-on-tag.yml)）。

文档权威副本：[workers-world-dot-github/docs/worker-compat-date.md](../workers-world-dot-github/docs/worker-compat-date.md)（meta 仓内路径）。
