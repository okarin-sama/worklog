#!/usr/bin/env bash
# ci/smoke.sh — dependency-free behaviour tests for the worklog toolkit.
# Runs WITHOUT twg or OpenProject credentials: exercises --help, the entry
# grammar parser, positional op: tag extraction (--print-map), the misplaced-tag
# warning, and the phase-1 dry-run plan. Used by GitHub CI and the local dev
# loop (see CONTRIBUTING.md). Exits non-zero when any check fails.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0; RUNS=0

ok()  { printf '  ok   %s\n' "$DESC"; }
bad() { printf '  FAIL %s\n' "$DESC"; [[ -s "$T/err" ]] && sed 's/^/         | /' "$T/err" | head -6; [[ -s "$T/out" ]] && sed 's/^/         > /' "$T/out" | head -6; FAILS=$((FAILS+1)); }
# helpers operate on the last-captured $T/out (stdout) and $T/err (stderr)
check()     { RUNS=$((RUNS+1)); if "$@" >>"$T/out" 2>"$T/err"; then ok; else bad; fi; }   # DESC must be set first
has()       { RUNS=$((RUNS+1)); grep -Eq -- "$1" "$T/out" && ok || bad; }                  # DESC + pattern
hasnt()     { RUNS=$((RUNS+1)); grep -Eq -- "$1" "$T/out" && bad || ok; }
warns()     { RUNS=$((RUNS+1)); grep -Eq -- "$1" "$T/err" && ok || bad; }
reset()     { : > "$T/out"; : > "$T/err"; }

WR="$ROOT/worklog-run.sh"

# ---- 1. --help works everywhere (and without twg) ------------------------------
echo "== help =="
DESC="worklog-run.sh --help";  check "$ROOT/worklog-run.sh" --help
DESC="worklog-add.sh --help";  check "$ROOT/worklog-add.sh" --help
DESC="worklog-summary.sh --help"; check "$ROOT/worklog-summary.sh" --help
DESC="op-sync.sh --help";      check "$ROOT/op-sync.sh" --help

# ---- 2. entry grammar + op: tag extraction -------------------------------------
echo "== grammar / print-map =="
cat > "$T/entries" <<'EOF'
# a comment line is not an entry

PILOT-17342 1h Today #soa
DEMO-421 1h Today op:65:Support #data architecture
SAMPLE-10516 2h Yesterday op:448:Testing UAT round 2
DEMO-435 1h 30m Today op:73 Test (sit) regression pass
INFRA-5321 30m op:65:4 compact no date
https://jira.example.com/browse/ABC-1 45m Today op:73:Test+(sit) from a link
ABC-2 1h Today late tag stays comment op:55:Nope
EOF
reset
RUNS=$((RUNS+1))
DESC="worklog-run --print-map exits 0"
WORKLOG_ENTRIES="$T/entries" "$WR" --print-map >>"$T/out" 2>"$T/err" \
  && ok || bad
DESC="map: plain op:<wp>:<name>";           has '^DEMO-421[[:space:]]+65[[:space:]]+Support'
DESC="map: split duration, no activity";    has '^DEMO-435[[:space:]]+73'
DESC="map: numeric activity id";            has '^INFRA-5321[[:space:]]+65[[:space:]]+4'
DESC="map: key resolved from Jira link";    has '^ABC-1[[:space:]]+73[[:space:]]+Test \(sit\)'
DESC="map: untagged key absent";            hasnt '^PILOT-17342'
DESC="map: misplaced-tag key absent";       hasnt '^ABC-2'
DESC="map: misplaced-tag warning on stderr"; warns 'misplaced op: tag'
RUNS=$((RUNS+1))
DESC="map: exactly 5 mapped rows"
[[ $(grep -Ec '^[A-Z][A-Z0-9]+-[0-9]+[[:space:]]' "$T/out") -eq 5 ]] && ok || bad

# ---- 3. phase-1 dry-run plan (no twg, nothing written) --------------------------
echo "== dry-run plan =="
reset
RUNS=$((RUNS+1))
DESC="worklog-run --jira-only --dry-run exits 0"
WORKLOG_ENTRIES="$T/entries" "$WR" --jira-only --dry-run --state "$T/state.log" >>"$T/out" 2>"$T/err" \
  && ok || bad
DESC="plan: all 7 entries planned";         has 'Planned worklogs \(7 entries\)'
DESC="plan: op tag stripped from comment";  has '"#data architecture"'
DESC="plan: twg cmd carries clean comment"; has -- "--comment '#data architecture'"
DESC="plan: comment after tag verbatim";    has 'late tag stays comment op:55:Nope'

# ---- 4. entries.example sanity ---------------------------------------------------
echo "== entries.example =="
reset
RUNS=$((RUNS+1))
DESC="entries.example parses (--print-map exit 0)"
WORKLOG_ENTRIES="$ROOT/entries.example" "$WR" --print-map >>"$T/out" 2>"$T/err" \
  && ok || bad
DESC="example: header-only file -> no mapped rows"; hasnt '^[A-Z][A-Z0-9]+-[0-9]+[[:space:]]'

echo ""
echo "== smoke: $RUNS checks, $FAILS failed =="
[[ $FAILS -eq 0 ]] || exit 1

