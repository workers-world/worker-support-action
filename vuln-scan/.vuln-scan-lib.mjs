#!/usr/bin/env node
// vuln-scan lib: parse osv-scanner JSON output, compute minimum patched versions,
// and apply security bumps to package.json (direct deps pinned exact; transitive
// deps via npm `overrides`).
//
// Commands:
//   node .vuln-scan-lib.mjs summarize <repo_dir> <osv_json>
//       -> one line per fixable vulnerable dep: pkg|section|installed|minfix|vuln_ids
//   node .vuln-scan-lib.mjs unfixable <repo_dir> <osv_json>
//       -> vulnerable deps with no patched release: pkg|installed|vuln_ids
//   node .vuln-scan-lib.mjs apply-fixes <repo_dir> <osv_json>
//       -> edit package.json in place; print applied lines (same format as summarize)
//
// npm ecosystem only (package-lock.json / npm-shrinkwrap.json). pnpm/yarn repos are
// reported by the scan but skipped by apply in the shell script (v1 scope).
import fs from 'node:fs';
import path from 'node:path';

const SECTIONS = ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies'];

// --- semver -----------------------------------------------------------------
function compareSemver(a, b) {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) return 0;
  const len = Math.max(pa.main.length, pb.main.length);
  for (let i = 0; i < len; i++) {
    const va = pa.main[i] ?? 0;
    const vb = pb.main[i] ?? 0;
    if (va !== vb) return va < vb ? -1 : 1;
  }
  // no prerelease > any prerelease
  if (!pa.pre && pb.pre) return 1;
  if (pa.pre && !pb.pre) return -1;
  if (pa.pre && pb.pre) {
    const pl = Math.max(pa.pre.length, pb.pre.length);
    for (let i = 0; i < pl; i++) {
      const ta = pa.pre[i];
      const tb = pb.pre[i];
      if (ta === undefined) return -1;
      if (tb === undefined) return 1;
      if (ta === tb) continue;
      const na = Number(ta);
      const nb = Number(tb);
      const aNum = Number.isInteger(na) && String(na) === ta;
      const bNum = Number.isInteger(nb) && String(nb) === tb;
      if (aNum && bNum) return na < nb ? -1 : 1;
      if (aNum) return -1;
      if (bNum) return 1;
      return ta < tb ? -1 : 1;
    }
  }
  return 0;
}

function parseVersion(v) {
  if (typeof v !== 'string') return null;
  let s = v.trim().replace(/^=/, '').replace(/^v/i, '');
  const m = s.match(/^(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$/);
  if (!m) return null;
  return { main: m[1].split('.').map(Number), pre: m[2] ? m[2].split('.') : null };
}

// pinned spec 已 >= 最低修复版本时不再改写（幂等）。range（^/~）不解析、视为未达标；
// weekly 流程输入是 fresh clone 扫描，正常只会遇到精确 pin。
function alreadyAtLeast(spec, minFix) {
  const v = parseVersion(spec);
  if (!v) return false;
  return compareSemver(spec, minFix) >= 0;
}

// --- osv parsing ------------------------------------------------------------
// OSV range event 显式类型：无类型对象上的 `ev.fixed` 属性访问会被 analyzer 弱解析到
// deprecated 的 String.prototype.fixed()（Qodana JSDeprecatedSymbols 误报）。
/** @typedef {{ introduced?: string, fixed?: string }} OsvEvent */

function readOsv(osvJsonPath) {
  return JSON.parse(fs.readFileSync(osvJsonPath, 'utf8'));
}

function pkgJsonPath(repoDir) {
  return path.join(repoDir, 'package.json');
}

function readRepoPackageJson(repoDir) {
  const p = pkgJsonPath(repoDir);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

// Collect (minFixed, vulnId) candidates for a vulnerable package at `installed`.
function minFixCandidates(vuln, pkgName, installed) {
  const candidates = [];
  const affectedList = Array.isArray(vuln?.affected) ? vuln.affected : [];
  for (const affected of affectedList) {
    const aName = affected?.package?.name ?? '';
    const aEco = affected?.package?.ecosystem ?? '';
    if (!namesMatch(aName, pkgName) || !/^npm$/i.test(aEco)) continue;
    for (const range of affected?.ranges ?? []) {
      if (!['SEMVER', 'ECOSYSTEM'].includes(range?.type)) continue;
      let introduced = null;
      const fixed = [];
      for (const ev of range?.events ?? []) {
        const event = /** @type {OsvEvent} */ (ev);
        if (typeof event?.introduced === 'string') {
          const v = event.introduced;
          if (v !== '0') introduced = introduced === null ? v : introduced;
        }
        if (typeof event?.fixed === 'string') fixed.push(event.fixed);
      }
      if (introduced !== null && compareSemver(installed, introduced) < 0) continue;
      for (const f of fixed) {
        if (compareSemver(installed, f) < 0) candidates.push(f);
      }
    }
  }
  return candidates;
}

function namesMatch(a, b) {
  return String(a).toLowerCase() === String(b).toLowerCase();
}

// Returns [{ name, section, installed, minFix, ids }]
export function summarizeFindings(repoDir, osvJsonPath) {
  const pkg = readRepoPackageJson(repoDir);
  if (!pkg) return { findings: [], unfixable: [] };
  const osv = readOsv(osvJsonPath);
  const findings = [];
  const unfixable = [];
  const seen = new Set();

  for (const result of osv?.results ?? []) {
    for (const group of result?.packages ?? []) {
      const name = group?.package?.name ?? '';
      const installed = group?.package?.version ?? '';
      if (!name || !installed) continue;
      for (const vuln of group?.vulnerabilities ?? []) {
        const candidates = minFixCandidates(vuln, name, installed);
        const ids = [vuln?.id, ...(vuln?.aliases ?? [])].filter(Boolean).slice(0, 4).join(',');
        if (!ids) continue;
        const key = `${name.toLowerCase()}@${installed}|${ids}`;
        if (seen.has(key)) continue;
        seen.add(key);
        if (candidates.length === 0) {
          unfixable.push({ name, installed, ids });
          continue;
        }
        const minFix = candidates.sort(compareSemver)[0];
        const section = findSection(pkg, name);
        findings.push({ name, section, installed, minFix, ids });
      }
    }
  }
  findings.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return { findings, unfixable };
}

function findSection(pkg, name) {
  for (const section of SECTIONS) {
    if (pkg?.[section] && Object.prototype.hasOwnProperty.call(pkg[section], name)) {
      return section;
    }
  }
  return null; // transitive-only
}

function formatLine(f) {
  return `${f.name}|${f.section ?? 'overrides'}|${f.installed}|${f.minFix}|${f.ids}`;
}

// --- apply ------------------------------------------------------------------
// Direct dep -> pin exact minFix in its own section.
// Transitive -> npm `overrides` pin exact minFix (existing keys untouched).
export function applyFixes(repoDir, osvJsonPath) {
  const pkgPath = pkgJsonPath(repoDir);
  const pkg = readRepoPackageJson(repoDir);
  if (!pkg) return [];
  const { findings } = summarizeFindings(repoDir, osvJsonPath);
  const applied = [];

  for (const f of findings) {
    if (f.section) {
      if (alreadyAtLeast(pkg[f.section][f.name], f.minFix)) continue;
      pkg[f.section][f.name] = f.minFix;
      applied.push(f);
    } else {
      if (!pkg.overrides || typeof pkg.overrides !== 'object' || Array.isArray(pkg.overrides)) {
        pkg.overrides = {};
      }
      if (Object.prototype.hasOwnProperty.call(pkg.overrides, f.name)) continue;
      pkg.overrides[f.name] = f.minFix;
      applied.push(f);
    }
  }

  if (applied.length > 0) {
    fs.writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);
  }
  for (const f of applied) process.stdout.write(`${formatLine(f)}\n`);
  return applied;
}

function main() {
  const [cmd, repoDir, osvJsonPath] = process.argv.slice(2);
  if (!repoDir || !osvJsonPath) {
    process.stderr.write('usage: .vuln-scan-lib.mjs <summarize|unfixable|apply-fixes> <repo_dir> <osv_json>\n');
    process.exit(1);
  }
  if (cmd === 'summarize') {
    const { findings } = summarizeFindings(repoDir, osvJsonPath);
    for (const f of findings) process.stdout.write(`${formatLine(f)}\n`);
    return;
  }
  if (cmd === 'unfixable') {
    const { unfixable } = summarizeFindings(repoDir, osvJsonPath);
    for (const u of unfixable) process.stdout.write(`${u.name}|${u.installed}|${u.ids}\n`);
    return;
  }
  if (cmd === 'apply-fixes') {
    applyFixes(repoDir, osvJsonPath);
    return;
  }
  process.stderr.write(`unknown command: ${cmd}\n`);
  process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
