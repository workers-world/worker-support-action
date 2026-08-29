# worker-support-action

公开仓自跑 **workers-world org 运维** workflow，省 meta 仓 `cloudflare_work` Actions 额度：

| Workflow | 频率 | 作用 |
|----------|------|------|
| [bump-compat-date.yml](.github/workflows/bump-compat-date.yml) | 每月 1 日 | 批量抬升各 Worker `compatibility_date` 并开 PR |
| [config-drift.yml](.github/workflows/config-drift.yml) | 每周一 | biome/npmrc/.github 漂移 + compat 过期检测，本仓开 issue |

Canonical 模板仍来自 [`workers-world/cloudflare_work`](https://github.com/workers-world/cloudflare_work) 的 `templates/`（workflow 内 sparse checkout）。

## 环境

| 名称 | 说明 |
|------|------|
| `GHA_TOKEN` / `GITHUB_TOKEN` | `gh` CLI；org 扫描、开 PR/issue |
| `NOTIFY_WORKER_URL` | Org Variable |
| `NOTIFY_GHA_TOKEN` | 发信（notify-worker 默认收件人） |

## 脚本

| 脚本 | 说明 |
|------|------|
| [bump-worker-compat-date.sh](bump-worker-compat-date.sh) | `--check` / `--apply` / `--remote --apply` |
| [check-config-drift-remote.sh](check-config-drift-remote.sh) | 远程 org 漂移检查 |

环境变量：

- `TEMPLATES_ROOT` — 默认 `$ROOT/templates`；CI 指向 checkout 的 `cloudflare_work/templates`
- `ISSUE_REPO` — 默认 `workers-world/worker-support-action`

## meta 仓本地用法

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
