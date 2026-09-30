#!/usr/bin/env bash
# ci/smoke.sh — dependency-free behaviour tests for the worklog toolkit.
# Runs WITHOUT twg or OpenProject credentials: exercises --help, the entry
# grammar parser, positional op: tag extraction (--print-map), the misplaced-tag
# warning, the phase-1 dry-run plan, and — through a stub `twg` on PATH — the
# issue links the summary report renders and the human-readable OpenProject
# time-entry comment op-sync builds (a stub `curl` answers the OP REST calls
# there). Both stubbed sections need jq, so they self-skip without it.
# Used by GitHub CI and the local dev loop (see CONTRIBUTING.md). Exits non-zero
# when any check fails.

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

# ---- 1b. work-package listing (--list-wps) guards ------------------------------
# Runs without any OpenProject access: the flag must appear in both help texts,
# and list mode without credentials must fail with the credentials hint —
# BEFORE any twg/mapping requirement (list mode needs neither).
echo "== list-wps =="
reset
RUNS=$((RUNS+1)); DESC="worklog-run --help lists --list-wps"; check bash -c "'$WR' --help | grep -q -- '--list-wps'"
reset
RUNS=$((RUNS+1)); DESC="op-sync --help lists --list-wps and --wp-filter"
check bash -c "'$ROOT/op-sync.sh' --help | grep -- '--list-wps' | grep -q -- '--wp-filter'"
RUNS=$((RUNS+1)); DESC="op-sync --list-wps without credentials fails"
env -u OP_BASE_URL -u OP_TOKEN "$ROOT/op-sync.sh" --list-wps >>"$T/out" 2>"$T/err" && bad || ok
DESC="list-wps: credentials hint on stderr"; warns 'need --url/--token'
DESC="list-wps: list mode never requires twg"; hasnt 'twg not found'
DESC="list-wps: list mode never requires the mapping file"; hasnt 'mapping file not found'
RUNS=$((RUNS+1)); DESC="worklog-run --list-wps without credentials fails (no entries file needed)"
(cd "$T" && env -u OP_BASE_URL -u OP_TOKEN -u WORKLOG_ENTRIES "$WR" --list-wps 5) \
  >>"$T/out" 2>"$T/err" && bad || ok
DESC="worklog-run list-wps: forwarded credentials hint"; warns 'need --url/--token'
reset

# ---- 1c. activity listing (--list-activities) guards ---------------------------
# Same contract without any OpenProject access: flag in both help texts, and
# list mode must fail with the credentials hint only — no twg, no mapping file.
echo "== list-activities =="
RUNS=$((RUNS+1)); DESC="worklog-run --help lists --list-activities"
check bash -c "'$WR' --help | grep -q -- '--list-activities'"
RUNS=$((RUNS+1)); DESC="op-sync --help lists --list-activities"
check bash -c "'$ROOT/op-sync.sh' --help | grep -q -- '--list-activities'"
RUNS=$((RUNS+1)); DESC="op-sync --list-activities without credentials fails"
env -u OP_BASE_URL -u OP_TOKEN "$ROOT/op-sync.sh" --list-activities >>"$T/out" 2>"$T/err" && bad || ok
DESC="list-activities: credentials hint on stderr"; warns 'need --url/--token'
DESC="list-activities: list mode never requires twg"; hasnt 'twg not found'
DESC="list-activities: list mode never requires the mapping file"; hasnt 'mapping file not found'
RUNS=$((RUNS+1)); DESC="worklog-run --list-activities without credentials fails (no entries file needed)"
(cd "$T" && env -u OP_BASE_URL -u OP_TOKEN -u WORKLOG_ENTRIES "$WR" --list-activities) \
  >>"$T/out" 2>"$T/err" && bad || ok
DESC="worklog-run list-activities: forwarded credentials hint"; warns 'need --url/--token'
reset

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

# ---- 5. worklog-summary issue links (fake twg, no credentials) -----------------
# The evidence table must link to the URL Jira returned, not to a hardcoded site.
# A stub `twg` on PATH lets the whole report path run offline. Skipped without jq
# (the summary needs it anyway, so there is nothing to test in that environment).
echo "== summary issue links =="
if command -v jq >/dev/null 2>&1; then
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/twg" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "twg-fake 0.0.0"; exit 0; }
case "${1:-} ${2:-}" in
  "work query")    cat "$FAKE_TWG_WQ" ;;
  "jira workitem") [[ "${3:-}" == "get" ]] && cat "$FAKE_TWG_GI" || cat "$FAKE_TWG_WL" ;;
  *)               echo '{"data":[]}' ;;
esac
SH
chmod +x "$BIN/twg"

# Two issues + one dated worklog, served by the stub for every scenario below.
cat > "$T/wl.json" <<'EOF'
{"data":[{"id":1,"started":"2026-09-28T09:00:00.000+0800","timeSpentSeconds":3600},
         {"id":2,"started":"2020-01-02T09:00:00.000+0800","timeSpentSeconds":600}]}
EOF
export FAKE_TWG_WQ="$T/wq.json" FAKE_TWG_GI="$T/gi.json" FAKE_TWG_WL="$T/wl.json"

wq_json() { # $1 = url|none|empty -> $FAKE_TWG_WQ
  if [[ "$1" == url ]]; then
    cat > "$FAKE_TWG_WQ" <<'EOF'
{"data":{"counts":{"sections":{"issues":{"matched":2}}},"items":{"sections":{
 "issues":[{"key":"DEMO-421","summary":"Alpha","webUrl":"https://jira.test.example/browse/DEMO-421"},
           {"key":"DEMO-435","summary":"Beta","webUrl":"https://jira.test.example/browse/DEMO-435?focusedCommentId=99"}],
 "comments":[],"pages":[],"pullRequests":[],"reviewedPullRequests":[]}}}}
EOF
  elif [[ "$1" == empty ]]; then
    cat > "$FAKE_TWG_WQ" <<'EOF'
{"data":{"counts":{"sections":{"issues":{"matched":0}}},"items":{"sections":{
 "issues":[],"comments":[],"pages":[],"pullRequests":[],"reviewedPullRequests":[]}}}}
EOF
  else
    cat > "$FAKE_TWG_WQ" <<'EOF'
{"data":{"counts":{"sections":{"issues":{"matched":2}}},"items":{"sections":{
 "issues":[{"key":"DEMO-421","summary":"Alpha"},{"key":"DEMO-435","summary":"Beta"}],
 "comments":[],"pages":[],"pullRequests":[],"reviewedPullRequests":[]}}}}
EOF
  fi
}
gi_json() { # $1 = url|none, $2 = request.site ("" to omit) -> $FAKE_TWG_GI
  local u421="" u435="" site=""
  if [[ "$1" == url ]]; then
    u421='"url":"https://jira.test.example/browse/DEMO-421",'
    u435='"url":"https://jira.test.example/browse/DEMO-435",'
  fi
  [[ -n "$2" ]] && site="\"site\":\"$2\","
  cat > "$FAKE_TWG_GI" <<EOF
{"request":{${site}"issueIdOrKey":["DEMO-421","DEMO-435"]},"data":{"items":[
 {"ok":true,"data":{"key":"DEMO-421","summary":"Alpha","status":{"name":"In Progress"},
  "timespent":4200,"created":"2026-09-01","updated":"2026-09-29","resolutiondate":"",${u421}"x":1}},
 {"ok":true,"data":{"key":"DEMO-435","summary":"Beta","status":{"name":"Waiting for approval"},
  "timespent":0,"created":"2026-09-02","updated":"2026-09-28","resolutiondate":"",${u435}"x":1}}]}}
EOF
}

run_summary() { # $1=wq-mode $2=gi-mode $3=request.site $4=TWG_SITE_URL ("" = unset)
  reset
  wq_json "$1"; gi_json "$2" "$3"
  if [[ -n "$4" ]]; then
    PATH="$BIN:$PATH" TWG_SITE_URL="$4" "$ROOT/worklog-summary.sh" 1 >>"$T/out" 2>"$T/err"
  else
    PATH="$BIN:$PATH" env -u TWG_SITE_URL -u JIRA_SITE_URL \
      "$ROOT/worklog-summary.sh" 1 >>"$T/out" 2>"$T/err"
  fi
}

RUNS=$((RUNS+1)); DESC="summary(fake): links use the payload webUrl"
run_summary url url "jira.test.example" "" && ok || bad
DESC="links: real URL rendered";                     has '\[DEMO-421\]\(https://jira\.test\.example/browse/DEMO-421\)'
DESC="links: no placeholder host in report";         hasnt 'jira\.example\.com'
DESC="links: site base attributed to the data";      has 'Jira site:\*\* https://jira\.test\.example'

RUNS=$((RUNS+1)); DESC="summary(fake): TWG_SITE_URL forces every link"
run_summary url url "jira.test.example" "https://proxy.test.example/jira" && ok || bad
DESC="override: links rebuilt from TWG_SITE_URL";    has '\[DEMO-421\]\(https://proxy\.test\.example/jira/browse/DEMO-421\)'
DESC="override: payload URL not used";               hasnt 'jira\.test\.example/browse/DEMO-421'
DESC="override: note names the env var";             has 'TWG_SITE_URL'

RUNS=$((RUNS+1)); DESC="summary(fake): graph webUrl used when hydration carries none"
run_summary url none "jira.test.example" "" && ok || bad
DESC="graph link: rendered for both rows";           has '\[DEMO-421\]\(https://jira\.test\.example/browse/DEMO-421\)'
DESC="graph link: query string stripped";            has '\[DEMO-435\]\(https://jira\.test\.example/browse/DEMO-435\)'
DESC="graph link: no query survives";                hasnt 'focusedCommentId=99\)'

RUNS=$((RUNS+1)); DESC="summary(fake): request.site fallback when no URL came back"
run_summary none none "jira.internal.test" "" && ok || bad
DESC="fallback: link synthesized from request.site"; has '\[DEMO-435\]\(https://jira\.internal\.test/browse/DEMO-435\)'
DESC="fallback: no placeholder warning";             hasnt 'could not be resolved'

RUNS=$((RUNS+1)); DESC="summary(fake): placeholder + warning when data says nothing"
run_summary none none "" "" && ok || bad
DESC="placeholder: link uses the neutral default";   has '\[DEMO-421\]\(https://jira\.example\.com/browse/DEMO-421\)'
DESC="placeholder: report warns about it";           has 'could not be resolved from any payload'

RUNS=$((RUNS+1)); DESC="summary(fake): zero issues still renders a report"
run_summary empty url "jira.test.example" "" && ok || bad
DESC="empty: report rendered without a table";      has 'No Jira issues matched'
DESC="empty: no link claim for nothing";            hasnt 'Issue links point at'
DESC="empty: unresolved site base is flagged";      has 'could not be resolved from any payload'

reset
else
  echo "  skip jq not installed"
fi

# ---- 6. op-sync human-readable OpenProject comments (fake twg + fake curl) -----
# The time-entry comment used to be a machine id that nobody could read in
# OpenProject. This drives the whole phase-2 read path offline: a stub `twg`
# answers the worklog query (note in Atlassian Document Format, exactly like the
# real API) and the ticket-context query, and a stub `curl` answers the
# OpenProject REST calls — so the exact planned POST payload is asserted with
# --dry-run against no Jira site and no OpenProject instance. Needs jq, so it
# self-skips where jq is missing.
echo "== op-sync comment readability =="
if command -v jq >/dev/null 2>&1; then
BIN2="$T/bin2"; mkdir -p "$BIN2"
cat > "$BIN2/twg" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "twg-fake 0.0.0"; exit 0; }
case "${1:-} ${2:-} ${3:-}" in
  "jira workitem get")     [[ "${FAKE_GI_FAIL:-}" == "1" ]] && exit 1
                           if [[ "${FAKE_GI_SHAPE:-batch}" == single ]]; then cat "$FAKE_TWG_GI1"
                           else cat "$FAKE_TWG_GI2"; fi ;;
  "jira workitem worklog") cat "$FAKE_TWG_WL2" ;;
  *)                       echo '{"data":[]}' ;;
esac
SH
# Answers every OpenProject endpoint the sync touches, and prints the status
# code on the last line the way `curl -w '\n%{http_code}'` does.
cat > "$BIN2/curl" <<'SH'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
case "$url" in
  */api/v3/users/me*)            printf '{"_type":"User","id":1,"login":"sync-bot"}\n200' ;;
  */api/v3/time_entries/schema*) printf '{"_type":"Schema","properties":{"workedAt":{},"duration":{}}}\n200' ;;
  */api/v3/time_entries*)        printf '{"_type":"TimeEntry","id":999}\n201' ;;
  *)                             printf '{"_type":"Collection","_embedded":{"elements":[]}}\n200' ;;
esac
SH
chmod +x "$BIN2/twg" "$BIN2/curl"

# One unsynced worklog (1h 30m on 2026-09-29) whose note, plus the ticket
# summary/description, all arrive in Atlassian Document Format.
cat > "$T/wl2.json" <<'EOF'
{
 "request": {
  "site": "jira.test.example"
 },
 "data": [
  {
   "id": "73681",
   "started": "2026-09-29T09:00:00.000+0800",
   "timeSpentSeconds": 5400,
   "author": {
    "displayName": "Ada Lovelace",
    "emailAddress": "ada@example.com"
   },
   "comment": {
    "type": "doc",
    "version": 1,
    "content": [
     {
      "type": "paragraph",
      "content": [
       {
        "type": "text",
        "text": "#demo mapped the report findings to the child tickets"
       }
      ]
     }
    ]
   }
  }
 ]
}
EOF
cat > "$T/gi2.json" <<'EOF'
{
 "request": {
  "site": "jira.test.example",
  "issueIdOrKey": [
   "DEMO-421",
   "DEMO-422"
  ]
 },
 "data": {
  "items": [
   {
    "input": "DEMO-421",
    "ok": true,
    "data": {
     "key": "DEMO-421",
     "summary": "Alpha  data  pipeline rollout",
     "description": {
      "type": "doc",
      "version": 1,
      "content": [
       {
        "type": "heading",
        "attrs": {
         "level": 1
        },
        "content": [
         {
          "type": "text",
          "text": "Scope of Work"
         }
        ]
       },
       {
        "type": "paragraph",
        "content": [
         {
          "type": "text",
          "text": "the targets are the staging endpoints "
         },
         {
          "type": "text",
          "text": "and were tested during business hours only"
         }
        ]
       }
      ]
     }
    }
   },
   {
    "input": "DEMO-422",
    "ok": false
   }
  ]
 }
}
EOF
# A one-key `workitem get` answers with a BARE .data array instead of
# .data.items — indexing .items on an array aborts jq, which used to drop the
# whole ticket context whenever the mapping held exactly one key.
cat > "$T/gi1.json" <<'EOF'
{
 "request": {
  "site": "jira.test.example",
  "issueIdOrKey": "DEMO-421"
 },
 "data": [
  {
   "key": "DEMO-421",
   "summary": "Alpha  data  pipeline rollout",
   "description": {
    "type": "doc",
    "version": 1,
    "content": [
     {
      "type": "paragraph",
      "content": [
       {
        "type": "text",
        "text": "the targets are the staging endpoints"
       },
       {
        "type": "text",
        "text": " and were tested during business hours only"
       }
      ]
     }
    ]
   }
  }
 ]
}
EOF
printf 'DEMO-421\t448\n' > "$T/map.tsv"
export FAKE_TWG_WL2="$T/wl2.json" FAKE_TWG_GI2="$T/gi2.json" FAKE_TWG_GI1="$T/gi1.json"

# opsync_run <gi-shape> [op-sync options] — the shape switch is set on the
# COMMAND, never before a function call (bash would keep it for later tests).
opsync_run() {
  local shape="$1"; shift
  reset
  PATH="$BIN2:$PATH" FAKE_GI_SHAPE="$shape" OP_SYNC_STATE="$T/opstate.log" \
    "$ROOT/op-sync.sh" 1 --url http://op.invalid --token FAKE --mapping "$T/map.tsv" \
    --dry-run "$@" >>"$T/out" 2>"$T/err"
}
opsync_dry() { opsync_run batch "$@"; }
opsync_gifail() {
  reset
  PATH="$BIN2:$PATH" FAKE_GI_SHAPE=batch FAKE_GI_FAIL=1 OP_SYNC_STATE="$T/opstate.log" \
    "$ROOT/op-sync.sh" 1 --url http://op.invalid --token FAKE --mapping "$T/map.tsv" \
    --dry-run >>"$T/out" 2>"$T/err"
}


RUNS=$((RUNS+1)); DESC="op-sync(fake): --dry-run with ticket context exits 0"
opsync_dry && ok || bad
DESC="comment: ticket summary joins the key, whitespace squeezed"; has 'DEMO-421 · Alpha data pipeline rollout'
DESC="comment: ADF ticket description flattened to prose";  has 'Ticket: Scope of Work the targets are the staging endpoints and were tested during business hours only'
DESC="comment: human duration, date and author";            has 'Logged: 1h 30m on 2026-09-29 by Ada Lovelace'
DESC="comment: the Jira worklog note is carried over";      has 'Worklog: #demo mapped the report findings to the child tickets'
DESC="comment: full Jira issue link kept";                  has 'Jira: https://jira[.]test[.]example/browse/DEMO-421'
DESC="comment: sync marker kept last for tracing";          has '^        [|] sync:jira-worklog-73681'
DESC="comment: the POSTed payload carries the same text";   has '"raw":"DEMO-421 · Alpha data pipeline rollout'
DESC="readability: the comment style is announced";         warns 'OP comment style: full'
RUNS=$((RUNS+1)); DESC="comment: an ok:false batch item is skipped, not fatal"
grep -Eq 'ticket context came back' "$T/err" && bad || ok

RUNS=$((RUNS+1)); DESC="op-sync(fake): a one-key answer (bare .data array) still yields context"
opsync_run single && ok || bad
DESC="single-shape: description read from the array answer"; has 'Ticket: the targets are the staging endpoints and were tested during business hours only'
DESC="single-shape: summary used";                           has 'DEMO-421 · Alpha data pipeline'
RUNS=$((RUNS+1)); DESC="single-shape: no ticket-context failure warning on stderr"
grep -Eq 'ticket context (unavailable|came back)' "$T/err" && bad || ok

RUNS=$((RUNS+1)); DESC="op-sync(fake): --comment-detail plain is the machine one-liner"
opsync_dry --comment-detail plain && ok || bad
DESC="plain: marker + link only";                            has 'sync:jira-worklog-73681 — https://jira[.]test[.]example/browse/DEMO-421 [(]op-sync[)]'
DESC="plain: no ticket description";                         hasnt 'Ticket: Scope of Work'
DESC="plain: no worklog line";                               hasnt 'Worklog: #demo'
RUNS=$((RUNS+1)); DESC="plain: skips the ticket-context read entirely"
grep -Eq 'OP comment style' "$T/err" && bad || ok

RUNS=$((RUNS+1)); DESC="op-sync(fake): --comment-detail brief keeps everything but the description"
opsync_dry --comment-detail brief && ok || bad
DESC="brief: summary kept";                                  has 'DEMO-421 · Alpha data pipeline'
DESC="brief: description dropped";                           hasnt 'Ticket: Scope of Work'
DESC="brief: worklog note kept";                             has 'Worklog: #demo'

RUNS=$((RUNS+1)); DESC="op-sync(fake): --comment-max clips long lines with an ellipsis"
opsync_dry --comment-max 40 && ok || bad
DESC="clip: description cut at 40 chars";                    has 'Ticket: Scope of Work the targets are the stagi…'
DESC="clip: the marker line is never clipped";               has 'sync:jira-worklog-73681'

RUNS=$((RUNS+1)); DESC="op-sync(fake): a failed ticket read degrades, never blocks"
opsync_gifail && ok || bad
DESC="degrade: warns that context is unavailable";           warns 'ticket context unavailable'
DESC="degrade: worklog note still written";                  has 'Worklog: #demo'
DESC="degrade: marker + link survive";                       has 'sync:jira-worklog-73681'

RUNS=$((RUNS+1)); DESC="op-sync --comment-detail bogus is rejected"
opsync_dry --comment-detail bogus && bad || ok
DESC="bogus mode: names the accepted ones";                  warns 'must be full[|]brief[|]plain'
RUNS=$((RUNS+1)); DESC="op-sync --comment-max 10 is rejected"
opsync_dry --comment-max 10 && bad || ok
DESC="tiny max: explains the floor";                         warns 'must be an integer >= 40'

RUNS=$((RUNS+1)); DESC="op-sync --help documents --comment-detail"
check bash -c "'$ROOT/op-sync.sh' --help | grep -q -- '--comment-detail'"
RUNS=$((RUNS+1)); DESC="op-sync --help documents --comment-max"
check bash -c "'$ROOT/op-sync.sh' --help | grep -q -- '--comment-max'"
RUNS=$((RUNS+1)); DESC="worklog-run --help documents --comment-detail"
check bash -c "'$WR' --help | grep -q -- '--comment-detail'"
RUNS=$((RUNS+1)); DESC="worklog-run --help documents --comment-max"
check bash -c "'$WR' --help | grep -q -- '--comment-max'"
reset
else
  echo "  skip jq not installed"
fi

echo ""
echo "== smoke: $RUNS checks, $FAILS failed =="
[[ $FAILS -eq 0 ]] || exit 1
