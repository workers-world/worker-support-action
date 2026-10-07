#!/usr/bin/env python3
"""Scan workers-world org repos and delete leftover merged-PR head branches."""

from __future__ import annotations

import fnmatch
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

META_FILE = ".pr-branch-cleanup-meta.json"
REPORT_FILE = "pr-branch-cleanup-report.md"

ROOT = Path(__file__).resolve().parent
DEFAULT_ALLOWLIST = ROOT / "pr-branch-cleanup.allowlist"
DEFAULT_EXCLUDE_REPOS = ROOT / "exclude-pr-branch-cleanup.txt"


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def load_name_list(path: Path, csv: str) -> set[str]:
    names: set[str] = set()
    for part in csv.split(","):
        part = part.strip()
        if part:
            names.add(part)
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                names.add(line)
    return names


def load_allowlist_patterns(path: Path, extra_csv: str) -> list[str]:
    patterns: list[str] = []
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                patterns.append(line)
    for part in extra_csv.split(","):
        part = part.strip()
        if part:
            patterns.append(part)
    if not patterns:
        patterns = ["main", "master", "gh-pages", "dev_*", "release/*"]
    return patterns


def branch_is_allowlisted(ref: str, patterns: list[str]) -> bool:
    for pat in patterns:
        if fnmatch.fnmatchcase(ref, pat):
            return True
    return False


class GhClient:
    def __init__(self) -> None:
        import subprocess

        self._subprocess = subprocess
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if not token:
            raise SystemExit("GH_TOKEN or GITHUB_TOKEN is required")
        self._env = os.environ.copy()
        self._env["GH_TOKEN"] = token

    def api(self, path: str, *, method: str = "GET", params: dict[str, str] | None = None) -> Any:
        args = ["gh", "api", path, "--method", method]
        if params:
            for key, val in params.items():
                args.extend(["-f", f"{key}={val}"])
        proc = self._subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            env=self._env,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "").strip()
            raise RuntimeError(f"gh api {path} ({method}): {err}")
        if not proc.stdout.strip():
            return None
        return json.loads(proc.stdout)

    def api_paginate(self, path: str) -> list[Any]:
        proc = self._subprocess.run(
            ["gh", "api", "--paginate", path],
            check=False,
            capture_output=True,
            text=True,
            env=self._env,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "").strip()
            raise RuntimeError(f"gh api --paginate {path}: {err}")
        items: list[Any] = []
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            chunk = json.loads(line)
            if isinstance(chunk, list):
                items.extend(chunk)
            else:
                items.append(chunk)
        return items


@dataclass
class RepoResult:
    full_name: str
    status: str = "ok"
    error: str = ""
    would_delete: list[str] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)


def list_org_repos(
    gh: GhClient,
    org: str,
    *,
    exclude_archived: bool,
    exclude_forks: bool,
    exclude_disabled: bool,
) -> list[dict[str, Any]]:
    repos = gh.api_paginate(f"/orgs/{org}/repos")
    out: list[dict[str, Any]] = []
    for repo in repos:
        if exclude_archived and repo.get("archived"):
            continue
        if exclude_forks and repo.get("fork"):
            continue
        if exclude_disabled and repo.get("disabled"):
            continue
        out.append(repo)
    return out


def encode_branch_ref(ref: str) -> str:
    from urllib.parse import quote

    return quote(ref, safe="")


def remote_branch_exists(gh: GhClient, owner: str, name: str, ref: str) -> bool:
    try:
        gh.api(f"/repos/{owner}/{name}/branches/{encode_branch_ref(ref)}")
        return True
    except RuntimeError:
        return False


def list_protected_branch_names(gh: GhClient, owner: str, name: str) -> set[str]:
    try:
        branches = gh.api_paginate(f"/repos/{owner}/{name}/branches?protected=true")
    except RuntimeError:
        return set()
    return {b.get("name", "") for b in branches if b.get("name")}


def fetch_closed_prs(gh: GhClient, owner: str, name: str) -> list[dict[str, Any]]:
    return gh.api_paginate(f"/repos/{owner}/{name}/pulls?state=closed")


def stale_closed_cutoff_days() -> int:
    raw = os.environ.get("INPUT_STALE_CLOSED_DAYS", "30").strip()
    try:
        return max(0, int(raw))
    except ValueError:
        return 30


def pr_is_stale_closed(pr: dict[str, Any], cutoff_days: int) -> bool:
    if pr.get("merged_at"):
        return False
    closed_at = pr.get("closed_at")
    if not closed_at:
        return False
    # ISO8601 from GitHub
    from datetime import datetime, timezone

    closed = datetime.fromisoformat(closed_at.replace("Z", "+00:00"))
    age = datetime.now(timezone.utc) - closed
    return age.total_seconds() >= cutoff_days * 86400


def head_on_same_repo(pr: dict[str, Any], owner: str, name: str) -> bool:
    head = pr.get("head") or {}
    head_repo = head.get("repo") or {}
    return head_repo.get("full_name") == f"{owner}/{name}"


def process_repo(
    gh: GhClient,
    repo: dict[str, Any],
    *,
    dry_run: bool,
    include_stale_closed: bool,
    allowlist: list[str],
) -> RepoResult:
    owner = repo["owner"]["login"]
    name = repo["name"]
    full = f"{owner}/{name}"
    result = RepoResult(full_name=full)

    default_branch = repo.get("default_branch") or "main"
    protected = list_protected_branch_names(gh, owner, name)

    try:
        prs = fetch_closed_prs(gh, owner, name)
    except RuntimeError as exc:
        result.status = "error"
        result.error = str(exc)
        return result

    cutoff = stale_closed_cutoff_days()
    candidates: dict[str, str] = {}

    for pr in prs:
        if not head_on_same_repo(pr, owner, name):
            continue
        ref = (pr.get("head") or {}).get("ref") or ""
        if not ref:
            continue
        if pr.get("merged_at"):
            reason = f"merged PR #{pr.get('number')}"
            candidates.setdefault(ref, reason)
        elif include_stale_closed and pr_is_stale_closed(pr, cutoff):
            reason = f"stale closed PR #{pr.get('number')}"
            candidates.setdefault(ref, reason)

    for ref, reason in sorted(candidates.items()):
        if ref == default_branch:
            result.skipped.append(f"{ref} (default branch)")
            continue
        if ref in protected:
            result.skipped.append(f"{ref} (protected)")
            continue
        if branch_is_allowlisted(ref, allowlist):
            result.skipped.append(f"{ref} (allowlist)")
            continue
        if not remote_branch_exists(gh, owner, name, ref):
            continue

        label = f"{ref} ({reason})"
        if dry_run:
            result.would_delete.append(label)
            eprint(f"DRY-RUN {full}: would delete {label}")
            continue

        try:
            gh.api(
                f"/repos/{owner}/{name}/git/refs/heads/{encode_branch_ref(ref)}",
                method="DELETE",
            )
            result.deleted.append(label)
            eprint(f"DELETE {full}: {label}")
        except RuntimeError as exc:
            result.skipped.append(f"{ref} (delete failed: {exc})")

    return result


def write_report(results: list[RepoResult], *, dry_run: bool, org: str) -> None:
    lines = [
        f"# PR branch cleanup ({org})",
        "",
        f"- mode: {'dry-run' if dry_run else 'apply'}",
        f"- repos processed: {sum(1 for r in results if r.status == 'ok')}",
        f"- repos errored: {sum(1 for r in results if r.status == 'error')}",
        "",
    ]
    for r in sorted(results, key=lambda x: x.full_name):
        if r.status == "skipped":
            continue
        if r.status == "error":
            lines.append(f"## {r.full_name} — ERROR")
            lines.append(f"- {r.error}")
            lines.append("")
            continue
        action = "would delete" if dry_run else "deleted"
        items = r.would_delete if dry_run else r.deleted
        if not items and not r.skipped:
            continue
        lines.append(f"## {r.full_name}")
        if items:
            lines.append(f"### {action}")
            for item in items:
                lines.append(f"- `{item}`")
        if r.skipped:
            lines.append("### skipped")
            for item in r.skipped[:20]:
                lines.append(f"- `{item}`")
            if len(r.skipped) > 20:
                lines.append(f"- … and {len(r.skipped) - 20} more")
        lines.append("")

    Path(REPORT_FILE).write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    org = os.environ.get("INPUT_ORG", "workers-world").strip()
    single_repo = os.environ.get("INPUT_REPO", "").strip()
    dry_run = env_bool("INPUT_DRY_RUN", True)
    include_stale_closed = env_bool("INPUT_INCLUDE_STALE_CLOSED", False)
    exclude_archived = env_bool("INPUT_EXCLUDE_ARCHIVED", True)
    exclude_forks = env_bool("INPUT_EXCLUDE_FORKS", True)
    exclude_disabled = env_bool("INPUT_EXCLUDE_DISABLED", True)

    allowlist_path = Path(os.environ.get("ALLOWLIST_FILE", str(DEFAULT_ALLOWLIST)))
    exclude_path = Path(os.environ.get("EXCLUDE_REPOS_FILE", str(DEFAULT_EXCLUDE_REPOS)))
    exclude_names = load_name_list(exclude_path, os.environ.get("INPUT_EXCLUDE_REPOS", ""))
    allowlist = load_allowlist_patterns(allowlist_path, os.environ.get("INPUT_EXTRA_ALLOWLIST", ""))

    gh = GhClient()

    try:
        repos = list_org_repos(
            gh,
            org,
            exclude_archived=exclude_archived,
            exclude_forks=exclude_forks,
            exclude_disabled=exclude_disabled,
        )
    except RuntimeError as exc:
        eprint(f"FATAL list repos: {exc}")
        return 1

    if single_repo:
        if "/" in single_repo:
            owner, name = single_repo.split("/", 1)
            repos = [r for r in repos if r.get("full_name") == f"{owner}/{name}"]
            if not repos:
                try:
                    repos = [gh.api(f"/repos/{owner}/{name}")]
                except RuntimeError as exc:
                    eprint(f"FATAL repo {single_repo}: {exc}")
                    return 1
        else:
            repos = [r for r in repos if r.get("name") == single_repo]

    results: list[RepoResult] = []
    errors = 0
    for repo in repos:
        name = repo.get("name", "")
        if name in exclude_names:
            results.append(RepoResult(full_name=repo.get("full_name", name), status="skipped"))
            continue
        try:
            res = process_repo(
                gh,
                repo,
                dry_run=dry_run,
                include_stale_closed=include_stale_closed,
                allowlist=allowlist,
            )
        except Exception as exc:  # noqa: BLE001 — per-repo isolation
            res = RepoResult(full_name=repo.get("full_name", name), status="error", error=str(exc))
        if res.status == "error":
            errors += 1
            eprint(f"ERROR {res.full_name}: {res.error}")
        results.append(res)
        time.sleep(0.05)

    write_report(results, dry_run=dry_run, org=org)

    meta = {
        "org": org,
        "dry-run": dry_run,
        "include-stale-closed": include_stale_closed,
        "repo-count": len(repos),
        "error-count": errors,
        "would-delete-count": sum(len(r.would_delete) for r in results),
        "deleted-count": sum(len(r.deleted) for r in results),
    }
    Path(META_FILE).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(meta))
    if errors:
        eprint(f"completed with {errors} repo error(s); see report")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
