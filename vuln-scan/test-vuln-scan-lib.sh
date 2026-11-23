#!/usr/bin/env bash
# vuln-scan lib 单测：osv JSON 解析 / 最低修复版本 / package.json 改写。
# fixture: fixtures/vuln-shape（direct dep / transitive / dev dep / 未受影响 / 无修复版本）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/.vuln-scan-lib.mjs"
FIXTURE="$SCRIPT_DIR/fixtures/vuln-shape"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cp "$FIXTURE/package.json" "$TMP/package.json"
cp "$FIXTURE/osv-results.json" "$TMP/osv-results.json"

# --- summarize ---------------------------------------------------------------
OUT="$(node "$LIB" summarize "$TMP" "$TMP/osv-results.json")"
grep -qx 'lodash|dependencies|4.17.15|4.17.19|GHSA-xxxx,CVE-2020-8203' <<< "$OUT" \
  || fail "summarize 应输出直接依赖 lodash → 4.17.19（含 CVE alias），got: $OUT"
grep -qx 'transitive-vuln|overrides|1.0.1|1.0.5|GHSA-trans' <<< "$OUT" \
  || fail "summarize 应把传递依赖归到 overrides，got: $OUT"
grep -qx 'dev-vuln-pkg|devDependencies|2.0.0|2.0.5|GHSA-dev' <<< "$OUT" \
  || fail "summarize 应命中 devDependencies，got: $OUT"
grep -q 'not-affected' <<< "$OUT" \
  && fail "introduced 高于 installed 的漏洞不应出现（not-affected）"
grep -q 'no-fix-yet' <<< "$OUT" \
  && fail "无修复版本的漏洞不应出现在 summarize（应进 unfixable）"
LINES="$(grep -c . <<< "$OUT" || true)"
[[ "$LINES" -eq 3 ]] || fail "summarize 应恰好 3 行，got $LINES"

# --- unfixable ---------------------------------------------------------------
UNFIX="$(node "$LIB" unfixable "$TMP" "$TMP/osv-results.json")"
grep -qx 'no-fix-yet|1.1.0|GHSA-open' <<< "$UNFIX" \
  || fail "unfixable 应只含 no-fix-yet，got: $UNFIX"

# --- apply-fixes -------------------------------------------------------------
APPLIED="$(node "$LIB" apply-fixes "$TMP" "$TMP/osv-results.json")"
[[ "$(grep -c . <<< "$APPLIED" || true)" -eq 3 ]] || fail "apply-fixes 应应用 3 项，got: $APPLIED"
node -e '
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const assert = require("assert");
assert.strictEqual(pkg.dependencies.lodash, "4.17.19", "direct dep pinned exact");
assert.strictEqual(pkg.dependencies["safe-pkg"], "^1.0.0", "unrelated dep untouched");
assert.strictEqual(pkg.devDependencies["dev-vuln-pkg"], "2.0.5", "dev dep pinned exact");
assert.strictEqual(pkg.overrides["transitive-vuln"], "1.0.5", "transitive dep via overrides");
assert.ok(!Object.hasOwn(pkg.overrides || {}, "no-fix-yet"), "unfixable not pinned");
' "$TMP/package.json" || fail "package.json 改写结果不符"
# 再跑一次 apply 不应叠加 / 覆盖已有 override
APPLIED2="$(node "$LIB" apply-fixes "$TMP" "$TMP/osv-results.json")"
[[ "$(grep -c . <<< "$APPLIED2" || true)" -eq 0 ]] || fail "重复 apply 应为幂等（0 项新增），got: $APPLIED2"

echo "vuln-scan lib tests passed"
