#!/usr/bin/env node
/**
 * Helpers for bump-cloudflare-npm-deps.sh (semver, peer-aware version pick, package.json edits).
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";

const SECTIONS = ["dependencies", "devDependencies", "peerDependencies"];

/** @typedef {{ name: string, allowMajor: boolean, peerFrom: string|null, peerKey: string|null }} AllowEntry */

function readPkg(pkgPath) {
  return JSON.parse(readFileSync(pkgPath, "utf8"));
}

function findDeclared(pkgJson, name) {
  for (const section of SECTIONS) {
    const block = pkgJson[section];
    if (block && Object.prototype.hasOwnProperty.call(block, name)) {
      return { section, current: block[name] };
    }
  }
  return null;
}

function findDeclaredVersion(pkgJson, name) {
  const found = findDeclared(pkgJson, name);
  return found ? found.current : "";
}

function npmView(args) {
  try {
    return execSync(`npm view ${args}`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function npmLatest(name) {
  return npmView(`${JSON.stringify(name)} version`);
}

/** @param {string} a @param {string} b */
function semverGt(a, b) {
  return semverLt(b, a);
}

/** @param {string[]} versions */
function maxSemverVersion(versions) {
  let best = "";
  for (const v of versions) {
    const core = String(v).replace(/^[^\d]*/, "");
    if (!best || semverGt(core, best)) {
      best = core;
    }
  }
  return best;
}

/** Highest published version matching a semver range (npm registry). */
function npmHighestInRange(name, range) {
  if (!range) return "";
  const quoted = `${JSON.stringify(name)}@${JSON.stringify(range)}`;
  const json = npmView(`${quoted} version --json`);
  if (!json) {
    return npmView(`${quoted} version`).split("\n").pop()?.replace(/^[^0-9]*/, "").trim() || "";
  }
  try {
    const parsed = JSON.parse(json);
    if (Array.isArray(parsed)) {
      return maxSemverVersion(parsed.map(String));
    }
    if (typeof parsed === "string") {
      return parsed;
    }
  } catch {
    /* fall through */
  }
  const lines = json.split("\n").map((l) => l.trim()).filter(Boolean);
  return maxSemverVersion(lines);
}

function formatRange(current, target) {
  const m = String(current).match(/^(\^|~|>=|>|<=|<|=)?/);
  const prefix = m && m[1] ? m[1] : "";
  if (prefix === "^" || prefix === "~") {
    return `${prefix}${target}`;
  }
  return target;
}

/** @returns {number[]|null} */
export function parseSemverCore(version) {
  const cleaned = String(version).replace(/^[^\d]*/, "");
  const m = cleaned.match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

export function semverLt(current, latest) {
  const a = parseSemverCore(current);
  const b = parseSemverCore(latest);
  if (!a || !b) return true;
  for (let i = 0; i < 3; i += 1) {
    if (a[i] < b[i]) return true;
    if (a[i] > b[i]) return false;
  }
  return false;
}

function isMajorBump(current, target) {
  const a = parseSemverCore(current);
  const b = parseSemverCore(target);
  if (!a || !b) return false;
  return b[0] > a[0];
}

function needsUpgrade(current, target) {
  if (!current || !target) return false;
  return semverLt(current, target);
}

/**
 * @param {string} allowlistPath
 * @returns {AllowEntry[]}
 */
export function parseAllowlist(allowlistPath) {
  const text = readFileSync(allowlistPath, "utf8");
  /** @type {AllowEntry[]} */
  const entries = [];
  for (const rawLine of text.split("\n")) {
    const line = rawLine.split("#")[0].trim();
    if (!line) continue;
    const parts = line.split(/\s+/);
    const name = parts[0];
    let allowMajor = false;
    /** @type {string|null} */
    let peerFrom = null;
    /** @type {string|null} */
    let peerKey = null;
    for (let i = 1; i < parts.length; i += 1) {
      const tok = parts[i];
      if (tok === "allowMajor") {
        allowMajor = true;
      } else if (tok.startsWith("peer:")) {
        const rest = tok.slice("peer:".length);
        const segs = rest.split(":");
        peerFrom = segs[0] || null;
        peerKey = segs[1] || name;
      }
    }
    entries.push({ name, allowMajor, peerFrom, peerKey });
  }
  return entries;
}

/**
 * Resolve peer dependency range for a package from an anchor (e.g. @cloudflare/vitest-pool-workers).
 * @param {string} repoDir
 * @param {object} pkgJson
 * @param {string} peerFrom
 * @param {string} peerKey
 * @returns {{ range: string, source: string }|null}
 */
export function resolvePeerRange(repoDir, pkgJson, peerFrom, peerKey) {
  const declared = findDeclaredVersion(pkgJson, peerFrom);
  if (declared) {
    const anchorVersion = npmHighestInRange(peerFrom, declared) || npmView(`${JSON.stringify(peerFrom)}@${JSON.stringify(declared)} version`);
    if (anchorVersion) {
      const peersJson = npmView(`${JSON.stringify(peerFrom)}@${JSON.stringify(anchorVersion)} peerDependencies --json`);
      if (peersJson) {
        try {
          const peers = JSON.parse(peersJson);
          if (peers && peers[peerKey]) {
            return {
              range: peers[peerKey],
              source: `peer:${peerFrom}@${anchorVersion}:${peerKey}:${peers[peerKey]}`,
            };
          }
        } catch {
          /* fall through */
        }
      }
    }
  }

  const nmPath = path.join(repoDir, "node_modules", peerFrom, "package.json");
  if (existsSync(nmPath)) {
    try {
      const anchorPkg = JSON.parse(readFileSync(nmPath, "utf8"));
      const peers = anchorPkg.peerDependencies || {};
      if (peers[peerKey]) {
        return {
          range: peers[peerKey],
          source: `peer:node_modules/${peerFrom}:${peerKey}:${peers[peerKey]}`,
        };
      }
    } catch {
      /* fall through */
    }
  }

  return null;
}

/**
 * Pick upgrade target version for one allowlist entry.
 * @param {string} repoDir
 * @param {object} pkgJson
 * @param {AllowEntry} entry
 * @param {string} current
 * @returns {{ target: string, versionSource: string }|null}
 */
export function pickTargetVersion(repoDir, pkgJson, entry, current) {
  const { name, allowMajor, peerFrom, peerKey } = entry;

  if (peerFrom && peerKey) {
    const peer = resolvePeerRange(repoDir, pkgJson, peerFrom, peerKey);
    if (!peer) {
      return null;
    }
    const target = npmHighestInRange(name, peer.range);
    if (!target || !needsUpgrade(current, target)) {
      return null;
    }
    if (isMajorBump(current, target) && !allowMajor) {
      return null;
    }
    return { target, versionSource: peer.source };
  }

  const latest = npmLatest(name);
  if (!latest || !needsUpgrade(current, latest)) {
    return null;
  }
  if (isMajorBump(current, latest) && !allowMajor) {
    return null;
  }
  return { target: latest, versionSource: "npm-latest" };
}

/**
 * @param {string} repoDir
 * @param {string} allowlistPath
 * @returns {Array<{ pkg: string, section: string, current: string, target: string, versionSource: string }>}
 */
export function listUpgrades(repoDir, allowlistPath) {
  const pkgPath = path.join(repoDir, "package.json");
  if (!existsSync(pkgPath)) return [];
  const pkgJson = readPkg(pkgPath);
  const allow = parseAllowlist(allowlistPath);
  /** @type {ReturnType<typeof listUpgrades>} */
  const out = [];
  for (const entry of allow) {
    const found = findDeclared(pkgJson, entry.name);
    if (!found) continue;
    const picked = pickTargetVersion(repoDir, pkgJson, entry, found.current);
    if (!picked) continue;
    out.push({
      pkg: entry.name,
      section: found.section,
      current: found.current,
      target: picked.target,
      versionSource: picked.versionSource,
    });
  }
  return out;
}

function applyUpgrades(repoDir, allowlistPath) {
  const pkgPath = path.join(repoDir, "package.json");
  const pkgJson = readPkg(pkgPath);
  const upgrades = listUpgrades(repoDir, allowlistPath);
  for (const u of upgrades) {
    pkgJson[u.section][u.pkg] = formatRange(u.current, u.target);
  }
  if (upgrades.length > 0) {
    writeFileSync(pkgPath, `${JSON.stringify(pkgJson, null, 2)}\n`, "utf8");
  }
  return upgrades.length;
}

function printUpgradeLine(u) {
  console.log(`${u.pkg}|${u.section}|${u.current}|${u.target}|${u.versionSource}`);
}

const cmd = process.argv[2];

if (cmd === "list-upgrades") {
  const repoDir = process.argv[3];
  const allowlistPath = process.argv[4];
  for (const u of listUpgrades(repoDir, allowlistPath)) {
    printUpgradeLine(u);
  }
  process.exit(0);
}

if (cmd === "apply-upgrades") {
  const repoDir = process.argv[3];
  const allowlistPath = process.argv[4];
  applyUpgrades(repoDir, allowlistPath);
  process.exit(0);
}

if (cmd === "list-one") {
  const pkgPath = process.argv[3];
  const pkgName = process.argv[4];
  const repoDir = path.dirname(pkgPath);
  const allowlistPath = process.env.ALLOWLIST_FILE || process.argv[5];
  if (!allowlistPath) {
    console.error("ALLOWLIST_FILE or allowlist path required");
    process.exit(1);
  }
  const allow = parseAllowlist(allowlistPath);
  const entry = allow.find((e) => e.name === pkgName);
  const pkgJson = readPkg(pkgPath);
  const found = findDeclared(pkgJson, pkgName);
  if (!found || !entry) process.exit(0);
  const picked = pickTargetVersion(repoDir, pkgJson, entry, found.current);
  if (!picked) process.exit(0);
  printUpgradeLine({
    pkg: pkgName,
    section: found.section,
    current: found.current,
    target: picked.target,
    versionSource: picked.versionSource,
  });
  process.exit(0);
}

if (cmd === "apply-one") {
  const pkgPath = process.argv[3];
  const pkgName = process.argv[4];
  const repoDir = path.dirname(pkgPath);
  const allowlistPath = process.env.ALLOWLIST_FILE || process.argv[5];
  if (!allowlistPath) {
    console.error("ALLOWLIST_FILE or allowlist path required");
    process.exit(1);
  }
  const allow = parseAllowlist(allowlistPath);
  const entry = allow.find((e) => e.name === pkgName);
  const pkgJson = readPkg(pkgPath);
  const found = findDeclared(pkgJson, pkgName);
  if (!found || !entry) process.exit(0);
  const picked = pickTargetVersion(repoDir, pkgJson, entry, found.current);
  if (!picked) process.exit(0);
  pkgJson[found.section][pkgName] = formatRange(found.current, picked.target);
  writeFileSync(pkgPath, `${JSON.stringify(pkgJson, null, 2)}\n`, "utf8");
  process.exit(0);
}

/** Offline assertions for CI (no npm registry). */
if (cmd === "self-test") {
  let failed = 0;
  const assert = (label, cond) => {
    if (!cond) {
      console.error(`FAIL ${label}`);
      failed += 1;
    } else {
      console.log(`ok ${label}`);
    }
  };

  assert("semverLt 3.2.0 vs 4.1.0", semverLt("3.2.0", "4.1.0"));
  assert("not semverLt 4.1.0 vs 4.1.0", !semverLt("4.1.0", "4.1.0"));
  assert("major bump detect", isMajorBump("^3.2.0", "4.1.0"));
  assert("not major patch", !isMajorBump("^4.1.0", "4.1.2"));

  const allow = parseAllowlist(process.argv[3]);
  assert("allowlist parses vitest peer", allow.some((e) => e.name === "vitest" && e.peerFrom === "@cloudflare/vitest-pool-workers"));

  const fixturesRoot = process.argv[4];
  if (fixturesRoot) {
    const cases = [
      { dir: "counter-worker-shape", expectPkg: "vitest", expectSkipMajor5: true, expectUpgrade: true },
      { dir: "lib-newbook-shape", expectPkg: "vitest", expectUpgrade: true },
      { dir: "invest-rss-shape", expectPkg: "vitest", expectUpgrade: false },
    ];
    for (const c of cases) {
      const repoDir = path.join(fixturesRoot, c.dir);
      const ups = listUpgrades(repoDir, process.argv[3]);
      const vit = ups.find((u) => u.pkg === "vitest");
      if (c.expectUpgrade) {
        assert(`${c.dir} proposes vitest upgrade`, Boolean(vit));
      }
      if (c.expectSkipMajor5 && vit) {
        assert(`${c.dir} vitest target not v5`, parseSemverCore(vit.target)[0] < 5);
      }
      if (vit) {
        assert(`${c.dir} vitest has peer source`, vit.versionSource.startsWith("peer:"));
      }
    }
  }

  process.exit(failed > 0 ? 1 : 0);
}

console.error(`unknown command: ${cmd}`);
process.exit(1);
