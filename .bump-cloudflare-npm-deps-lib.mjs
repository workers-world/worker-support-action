#!/usr/bin/env node
/**
 * Helpers for bump-cloudflare-npm-deps.sh (semver compare, npm latest, package.json edits).
 */
import { readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";

const SECTIONS = ["dependencies", "devDependencies", "peerDependencies"];

function readPkg(path) {
  return JSON.parse(readFileSync(path, "utf8"));
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

function npmLatest(name) {
  try {
    return execSync(`npm view ${JSON.stringify(name)} version`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function formatRange(current, latest) {
  const m = String(current).match(/^(\^|~|>=|>|<=|<|=)?/);
  const prefix = m && m[1] ? m[1] : "";
  if (prefix === "^" || prefix === "~") {
    return `${prefix}${latest}`;
  }
  return latest;
}

/** @returns {number[]|null} */
function parseSemverCore(version) {
  const cleaned = String(version).replace(/^[^\d]*/, "");
  const m = cleaned.match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

function semverLt(current, latest) {
  const a = parseSemverCore(current);
  const b = parseSemverCore(latest);
  if (!a || !b) return true;
  for (let i = 0; i < 3; i += 1) {
    if (a[i] < b[i]) return true;
    if (a[i] > b[i]) return false;
  }
  return false;
}

function needsUpgrade(current, latest) {
  if (!current || !latest) return false;
  return semverLt(current, latest);
}

const cmd = process.argv[2];

if (cmd === "list-one") {
  const pkgPath = process.argv[3];
  const pkgName = process.argv[4];
  const pkgJson = readPkg(pkgPath);
  const found = findDeclared(pkgJson, pkgName);
  if (!found) process.exit(0);
  const latest = npmLatest(pkgName);
  if (!latest || !needsUpgrade(found.current, latest)) process.exit(0);
  console.log(`${pkgName}|${found.section}|${found.current}|${latest}`);
  process.exit(0);
}

if (cmd === "apply-one") {
  const pkgPath = process.argv[3];
  const pkgName = process.argv[4];
  const pkgJson = readPkg(pkgPath);
  const found = findDeclared(pkgJson, pkgName);
  if (!found) process.exit(0);
  const latest = npmLatest(pkgName);
  if (!latest || !needsUpgrade(found.current, latest)) process.exit(0);
  pkgJson[found.section][pkgName] = formatRange(found.current, latest);
  writeFileSync(pkgPath, `${JSON.stringify(pkgJson, null, 2)}\n`, "utf8");
  process.exit(0);
}

console.error(`unknown command: ${cmd}`);
process.exit(1);
