#!/usr/bin/env python3
"""Scan GitHub org or single public repo with gitleaks (full git history)."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

META_FILE = ".scan-meta.json"
REDACTED_KEYS = frozenset(
    {
        "Match",
        "Secret",
        "Entropy",
        "Author",
        "Email",
        "Message",
    }
)


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def run_cmd(args: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if check and proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"{' '.join(args)} failed ({proc.returncode}): {err}")
    return proc


def run_gh(args: list[str]) -> str:
    env = os.environ.copy()
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    if token:
        env["GH_TOKEN"] = token
    proc = subprocess.run(
        ["gh", *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"gh {' '.join(args)} failed: {err}")
    return proc.stdout


def load_excludes(exclude_file: str, exclude_csv: str) -> set[str]:
    names: set[str] = set()
    for part in exclude_csv.split(","):
        part = part.strip()
        if part:
            names.add(part)
    if exclude_file.strip():
        path = Path(exclude_file)
        if path.is_file():
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.split("#", 1)[0].strip()
                if line:
                    names.add(line)
    return names


def resolve_repo_entries(org: str, repo: str, visibility: str) -> tuple[str, list[str]]:
    org = org.strip()
    repo = repo.strip()
    visibility = (visibility or "public").strip().lower()
    if visibility not in {"public", "private", "all"}:
        raise SystemExit("INPUT_VISIBILITY must be public, private, or all")

    if repo:
        if "/" in repo:
            owner, name = repo.split("/", 1)
            full = f"{owner}/{name}"
        else:
            if not org:
                raise SystemExit("repo short name requires org input")
            owner, name = org, repo
            full = f"{org}/{repo}"
        if visibility != "all":
            info = json.loads(run_gh(["api", f"repos/{owner}/{name}", "--jq", "{private: .private}"]))
            is_private = bool(info.get("private"))
            if visibility == "public" and is_private:
                raise SystemExit(f"repo {full} is private (visibility=public)")
            if visibility == "private" and not is_private:
                raise SystemExit(f"repo {full} is public (visibility=private)")
        return f"repo:{full}", [full]

    if not org:
        raise SystemExit("org or repo is required")

    rows = json.loads(
        run_gh(
            [
                "repo",
                "list",
                org,
                "--json",
                "name,isPrivate",
                "--limit",
                "500",
            ]
        )
    )
    entries: list[str] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = str(row.get("name") or "")
        is_private = bool(row.get("isPrivate"))
        if visibility == "public" and is_private:
            continue
        if visibility == "private" and not is_private:
            continue
        entries.append(name)
    return f"org:{org}", entries


def repo_owner_name(org: str, repo_entry: str) -> tuple[str, str]:
    if "/" in repo_entry:
        owner, name = repo_entry.split("/", 1)
        return owner, name
    return org, repo_entry


def sanitize_finding(raw: dict[str, object]) -> dict[str, object]:
    clean: dict[str, object] = {}
    for key, value in raw.items():
        if key in REDACTED_KEYS:
            continue
        clean[key] = value
    return clean


def run_gitleaks(
    gitleaks_bin: str,
    repo_dir: Path,
    report_path: Path,
    config_path: Path | None,
) -> list[dict[str, object]]:
    args = [
        gitleaks_bin,
        "detect",
        "--source",
        str(repo_dir),
        "--report-format",
        "json",
        "--report-path",
        str(report_path),
        "--exit-code",
        "0",
        "--no-banner",
    ]
    if config_path and config_path.is_file():
        args.extend(["--config", str(config_path)])

    env = os.environ.copy()
    proc = run_cmd(args, env=env, check=False)
    if proc.returncode not in (0, 1):
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"gitleaks failed on {repo_dir.name}: {err}")

    if not report_path.is_file() or report_path.stat().st_size == 0:
        return []
    data = json.loads(report_path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


def build_markdown(scope: str, scanned: int, findings: list[dict[str, object]]) -> str:
    lines = [
        f"# Secret scan: {scope}",
        "",
        f"Scanned **{scanned}** public repo(s). Findings: **{len(findings)}** (values redacted).",
        "",
    ]
    if not findings:
        lines.append("No secrets detected.")
        return "\n".join(lines).rstrip() + "\n"

    by_repo: dict[str, list[dict[str, object]]] = {}
    for item in findings:
        repo = str(item.get("repo") or "unknown")
        by_repo.setdefault(repo, []).append(item)

    for repo in sorted(by_repo):
        rows = by_repo[repo]
        lines.append(f"## {repo} ({len(rows)})")
        lines.append("")
        for row in rows:
            rule = row.get("RuleID") or row.get("Description") or "unknown-rule"
            file_path = row.get("File") or "?"
            start = row.get("StartLine") or "?"
            commit = row.get("Commit")
            commit_short = str(commit)[:7] if commit else "?"
            lines.append(f"- `{rule}` — `{file_path}`:{start} (commit `{commit_short}`)")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def maybe_create_issue(issue_repo: str, finding_count: int, md_path: Path) -> None:
    if finding_count <= 0 or not issue_repo.strip():
        return
    if os.environ.get("INPUT_CREATE_ISSUE", "false").lower() != "true":
        return
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        return
    body = md_path.read_text(encoding="utf-8")
    run_gh(
        [
            "issue",
            "create",
            "--repo",
            issue_repo,
            "--title",
            f"secret scan: {finding_count} finding(s)",
            "--body",
            body,
        ]
    )
    print(f"issue created on {issue_repo}")


def write_meta(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    root = Path(__file__).resolve().parent
    org = os.environ.get("INPUT_ORG", "")
    repo = os.environ.get("INPUT_REPO", "")
    visibility = os.environ.get("INPUT_VISIBILITY", "public")
    exclude_file = os.environ.get("INPUT_EXCLUDE_FILE", "").strip()
    if not exclude_file:
        exclude_file = str(root / "exclude-secrets.txt")
    exclude_csv = os.environ.get("INPUT_EXCLUDE", "")
    json_out = os.environ.get("INPUT_JSON_OUT", "secrets-scan.json")
    md_out = os.environ.get("INPUT_MD_OUT", "secrets-scan.md")
    issue_repo = os.environ.get("ISSUE_REPO", "workers-world/worker-support-action")
    gitleaks_bin = os.environ.get("GITLEAKS_BIN", "gitleaks")

    if not shutil.which(gitleaks_bin) and not Path(gitleaks_bin).is_file():
        raise SystemExit(f"gitleaks not found: {gitleaks_bin}")

    config_path = root / "gitleaks.toml"
    scope, repo_entries = resolve_repo_entries(org, repo, visibility)
    excludes = load_excludes(exclude_file, exclude_csv)

    workdir = Path(tempfile.mkdtemp(prefix="secret-scan-"))
    all_findings: list[dict[str, object]] = []
    scanned = 0
    errors: list[str] = []

    try:
        for entry in repo_entries:
            owner, name = repo_owner_name(org, entry)
            short = name if owner == org or not org else f"{owner}/{name}"
            if excludes and short in excludes:
                continue
            scanned += 1
            clone_dir = workdir / name.replace("/", "_")
            clone_dir.mkdir(parents=True, exist_ok=True)
            try:
                run_gh(["repo", "clone", f"{owner}/{name}", str(clone_dir)])
            except RuntimeError as exc:
                errors.append(f"{short}: clone failed ({exc})")
                eprint(errors[-1])
                continue

            report_file = workdir / f"{name.replace('/', '_')}.gitleaks.json"
            try:
                raw_findings = run_gitleaks(gitleaks_bin, clone_dir, report_file, config_path)
            except RuntimeError as exc:
                errors.append(f"{short}: {exc}")
                eprint(errors[-1])
                continue

            for item in raw_findings:
                sanitized = sanitize_finding(item)
                sanitized["repo"] = short
                all_findings.append(sanitized)

            if raw_findings:
                eprint(f"FINDINGS {short}: {len(raw_findings)}")
            else:
                eprint(f"OK {short}")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    md_text = build_markdown(scope, scanned, all_findings)
    Path(md_out).write_text(md_text, encoding="utf-8")
    Path(json_out).write_text(
        json.dumps(all_findings, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    finding_count = len(all_findings)
    write_meta(
        Path(META_FILE),
        {
            "scope": scope,
            "repo-count": scanned,
            "finding-count": finding_count,
            "has-findings": finding_count > 0,
            "json-file": json_out,
            "md-file": md_out,
            "errors": errors,
        },
    )

    if errors and scanned == 0 and finding_count == 0:
        raise SystemExit(f"scan failed: {'; '.join(errors[:5])}")

    if finding_count == 0:
        print(f"no secrets found in {scanned} repo(s) ({scope})")
        return 0

    maybe_create_issue(issue_repo, finding_count, Path(md_out))
    print(f"secrets found: {finding_count} across {scanned} repo(s) ({scope})")
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit as exc:
        if str(exc):
            eprint(str(exc))
        raise
