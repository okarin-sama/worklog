#!/usr/bin/env bash
# worklog-summary.sh — TWG worklog + time-tracking summary over N weeks.
#
# Usage:
#   ./worklog-summary.sh [WEEKS] [options]
#
# Positional:
#   WEEKS            Number of weeks to look back (default: 1)
#
# Options:
#   --identifier X   Scope to another user (repeatable; AAID or IdentityUser ARI)
#   --items N        Max hydrated items per section (default: 10)
#   --max-issues N   Max issues to pull worklogs for (default: 15)
#   --date-columns N Max dated columns in the evidence table (default: 10; 0 = all)
#   --all-time       (kept for compatibility, now a no-op) — a column per dated log is
#                    the default: worklogs are fetched for every date ever logged
#   -o FILE          Also write the markdown report to FILE
#   --help           Show this help
#
# What it does (all read-only):
#   1. twg work query        -> ranked activity across Jira/PR/docs/comments
#   2. twg jira workitem get -> batched status + lifetime time-tracking fields
#   3. twg jira workitem worklog query -> lifetime worklog entries, kept per date
#   4. Renders a prose standup summary + a markdown evidence table that automatically
#      grows one column per date that has a log entry (today / yesterday / any day so
#      far) — no flag needed.

set -euo pipefail

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

# ---- launcher fallback -------------------------------------------------------
if ! command -v twg >/dev/null 2>&1; then
  if [[ -x "$HOME/.local/bin/twg" ]]; then TWG="$HOME/.local/bin/twg"
  else echo "twg not found on PATH or in ~/.local/bin" >&2; exit 1; fi
else TWG="twg"; fi

# ---- args --------------------------------------------------------------------
WEEKS="${1:-1}"; if [[ $# -gt 0 ]]; then shift; fi
case "$WEEKS" in -h|--help) usage; exit 0;; esac
[[ "$WEEKS" =~ ^[0-9]+$ && "$WEEKS" -ge 1 ]] || { echo "WEEKS must be a positive integer" >&2; exit 1; }

SCOPE="me"; IDENT=(); ITEMS=10; MAXKEYS=15; OUT=""
DATE_COLS=10; WL_PAGE=200
SITE_URL="${TWG_SITE_URL:-https://jira.example.com}"   # override via env for other sites
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identifier)   SCOPE="user"; IDENT+=(--identifier "$2"); shift 2;;
    --items)        ITEMS="$2"; shift 2;;
    --max-issues)   MAXKEYS="$2"; shift 2;;
    --date-columns) DATE_COLS="$2"; shift 2;;
    --all-time)     shift;;  # no-op: every dated log already gets a column
    -o)             OUT="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *)              echo "unknown option: $1" >&2; exit 1;;
  esac
done

[[ "$DATE_COLS" =~ ^[0-9]+$ ]] || { echo "--date-columns must be a non-negative integer" >&2; exit 1; }
[[ "$MAXKEYS" =~ ^[0-9]+$ && "$MAXKEYS" -ge 1 ]] || { echo "--max-issues must be a positive integer" >&2; exit 1; }
[[ "$ITEMS" =~ ^[0-9]+$ ]] || { echo "--items must be a non-negative integer" >&2; exit 1; }

DAYS=$(( WEEKS * 7 ))
WINSTART="$(date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "-${DAYS} days" +%Y-%m-%d)"
WINDOW_LABEL="${WEEKS} week(s) · last ${DAYS} days"

# ---- pre-flight: verify twg runs and auth is alive ----------------------------
if ! "$TWG" --version >/dev/null 2>&1; then
  echo "ERROR: '$TWG' is not runnable. Output of '$TWG --version':" >&2
  "$TWG" --version >&2 || true
  exit 1
fi
for dep in jq awk sed grep; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: required tool '$dep' not found" >&2; exit 1; }
done

# ---- helpers -----------------------------------------------------------------
# Run a twg command with JSON output; echo the path of its raw stdout JSON file.
# Diagnostics go to stderr on failure (envelope parse or twg error).
run_twg() {
  local env errf line p raw
  errf="$(mktemp /tmp/wlg.err.XXXXXX)"
  env="$("$TWG" "$@" --output json 2>"$errf")" || true
  # 1) envelope with temp-file reference (agent output mode)
  line="$(printf '%s\n' "$env" | grep -m1 -E '^[[:space:]]*stdout:' || true)"
  if [[ -z "$line" ]]; then
    line="$(printf '%s\n' "$env" | grep -m1 -E '^[[:space:]]*compact:' || true)"
  fi
  p="$(printf '%s\n' "$line" | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')"
  if [[ -n "$p" && -f "$p" ]]; then rm -f "$errf"; printf '%s\n' "$p"; return 0; fi
  # 2) plain raw JSON printed straight to stdout (no envelope)
  if [[ -n "$env" && "${env:0:1}" == "{" ]]; then
    raw="$(mktemp /tmp/wlg.raw.XXXXXX)" || raw=""
    if [[ -n "$raw" ]] && printf '%s\n' "$env" > "$raw" && printf '%s' "$env" | jq -e . >/dev/null 2>&1; then
      rm -f "$errf"; printf '%s\n' "$raw"; return 0
    fi
    rm -f "$raw"
  fi
  # 3) failure: surface everything we got
  { echo "--- twg command failed: $* ---" >&2
    [[ -n "$env" ]] && { echo "--- twg stdout (first 20 lines) ---" >&2; printf '%s\n' "$env" | head -20 >&2; }
    [[ -s "$errf" ]] && { echo "--- twg stderr (first 20 lines) ---" >&2; head -20 "$errf" >&2; }
    echo "Hint: run the failing twg command directly in your terminal to see its full error." >&2; }
  rm -f "$errf"; return 1
}

die_missing() { # $1=path $2=what
  if [[ -z "${1:-}" || ! -f "$1" ]]; then
    echo "ERROR: no JSON output for: $2" >&2
    echo "Pre-flight check — run this directly and fix any error it shows:" >&2
    echo "  $TWG work query --scope me --since 1d --counts-only --output json" >&2
    exit 1
  fi
}

fmt_dur() { # seconds -> "Xh Ym"
  local s=${1:-0}
  printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

# ---- 1. baseline activity ----------------------------------------------------
echo ">>> work query (scope=$SCOPE, since=${DAYS}d) ..." >&2
WQ="$(run_twg work query --scope "$SCOPE" "${IDENT[@]+"${IDENT[@]}"}" \
      --activity all --ranked --since "${DAYS}d" --items-per-section "$ITEMS")"
die_missing "$WQ" "work query"

COUNTS="$(jq -r '[.data.counts.sections // {} | to_entries[]
                  | select(.value.matched > 0)
                  | "\(.key)=\(.value.matched)"] | join(" · ") // ""' "$WQ" 2>/dev/null || true)"
[[ -n "$COUNTS" ]] || COUNTS="(no activity returned)"

# ---- 2. issue keys: explicit items + any referenced in comment URLs ----------
# `|| true` keeps a "no activity yet" (empty grep) run alive under pipefail.
KEYS="$( { jq -r '.data.items.sections.issues[]?.key // empty' "$WQ" 2>/dev/null
          jq -r '.data.items.sections.comments[]?.webUrl // empty' "$WQ" 2>/dev/null \
            | sed -nE 's|.*/browse/([A-Z][A-Z0-9]+-[0-9]+).*|\1|p'
        } | grep -E '^[A-Z][A-Z0-9]+-[0-9]+$' | sort -u | head -n "$MAXKEYS" || true )"

# ---- 2b. batched workitem hydration ------------------------------------------
GI=""
if [[ -n "$KEYS" ]]; then
  echo ">>> jira workitem get (batch: $(printf '%s\n' "$KEYS" | wc -w | tr -d ' ') issues) ..." >&2
  # shellcheck disable=SC2086
  GI="$(run_twg jira workitem get $KEYS --fields summary,status,timespent,timeoriginalestimate,created,updated,resolutiondate)"
fi

# issue key -> tab-separated: summary, status, lifetime timespent s, created, updated, completed
# "jira workitem get" answers with .data.items[] for a batch but a bare .data[]
# array for a single issue — accept both shapes so 1-issue runs still hydrate.
ISSUE_META="/tmp/wlg.meta.$$.tsv"
: > "$ISSUE_META"
if [[ -n "$GI" && -f "$GI" ]]; then
  jq -r '
    ( if (.data | type) == "array" then (.data[] | select(type == "object"))
      elif (.data | type) == "object" and ((.data.items | type) == "array")
        then (.data.items[] | select(.ok) | .data)
      else empty end )
    | [ .key,
        ((.summary // "n/a") | gsub("\t";" ")),
        ((if (.status | type) == "object" then .status.name else .status end) // "n/a"),
        ((.timespent // .timespentSeconds // 0) | floor | tostring),
        ((.created // "") | tostring | split("T")[0]),
        ((.updated // "") | tostring | split("T")[0]),
        ((.resolutiondate // "") | tostring | split("T")[0]) ]
    | @tsv' "$GI" > "$ISSUE_META" 2>/dev/null || true
fi

# ---- 3. per-issue worklogs, one row per (issue, date) entry -------------------
echo ">>> worklog query per issue (dated entries) ..." >&2
WL_ENTRIES="/tmp/wlg.entries.$$.tsv"   # issue \t date \t seconds  (one line per worklog entry)
: > "$WL_ENTRIES"
# Fetch LIFETIME worklogs — no started-after window filter — so that ANY date carrying
# a log (today, yesterday, months ago) produces its own dated column in the table.
for k in $KEYS; do
  KW="$(run_twg jira workitem worklog query --issue-id "$k" --first "$WL_PAGE")" || KW=""
  if [[ -n "$KW" && -f "$KW" ]]; then
    jq -r --arg k "$k" '
      .data[]? | [ $k,
                   ((.started // "") | tostring | split("T")[0]),
                   ((.timeSpentSeconds // .time_spent_seconds // 0) | floor | tostring) ]
      | select(.[1] != "") | @tsv' "$KW" >> "$WL_ENTRIES" 2>/dev/null || true
  fi
done

# dated column set: every date that has at least one worklog entry
DATES_ALL="/tmp/wlg.dates.$$.txt"
awk -F'\t' '$2 != "" {print $2}' "$WL_ENTRIES" | sort -u > "$DATES_ALL"
NDATES="$(awk 'END { print NR+0 }' "$DATES_ALL")"
if (( DATE_COLS > 0 && NDATES > DATE_COLS )); then
  FIRST_SHOWN=$(( NDATES - DATE_COLS + 1 ))
else
  FIRST_SHOWN=1
fi
# DATELIST: date \t label(MM-DD) \t shown(1|0)  — shown=0 dates fold into one "≤ MM-DD" column
DATELIST="/tmp/wlg.datelist.$$.tsv"
awk -v first="$FIRST_SHOWN" '{ printf "%s\t%s\t%d\n", $1, substr($1, 6), (NR >= first ? 1 : 0) }' \
  "$DATES_ALL" > "$DATELIST"
SHOWN_DATES="$(awk -F'\t' '$3 == 1' "$DATELIST" | wc -l | tr -d ' ')"
EARLIER_COL=0
if [[ "$(awk -F'\t' '$3 == 0 {c++} END {print c+0}' "$DATELIST")" -gt 0 ]]; then EARLIER_COL=1; fi

TOTAL_SECS="$(awk -F'\t' -v ws="$WINSTART" '($2 "") >= (ws "") { s += $3 } END { print s + 0 }' "$WL_ENTRIES")"
TOTAL_SECS_ALL="$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$WL_ENTRIES")"
NWL="$(awk 'END { print NR + 0 }' "$WL_ENTRIES")"
NTRACKED="$(awk -F'\t' -v ws="$WINSTART" '($2 "") >= (ws "") && $3 + 0 > 0 { print $1 }' "$WL_ENTRIES" | sort -u | wc -l | tr -d ' ')"

# "09-21: 3h · 09-25: 2h" digest of every dated column (hidden dates folded into ≤ MM-DD)
DAILY=""; EARLY_SECS=0; EARLY_LABEL=""
while IFS=$'\t' read -r d lbl shown; do
  s="$(awk -F'\t' -v d="$d" '($2 "") == (d "") { t += $3 } END { print t + 0 }' "$WL_ENTRIES")"
  if [[ "$shown" == 1 ]]; then
    DAILY+="${lbl}: $(fmt_dur "$s") · "
  else
    EARLY_SECS=$(( EARLY_SECS + s )); EARLY_LABEL="$lbl"
  fi
done < "$DATELIST"
DAILY="${DAILY% · }"
if (( EARLY_SECS > 0 )); then
  DAILY="≤ ${EARLY_LABEL}: $(fmt_dur "$EARLY_SECS") · ${DAILY}"
fi

DAILY_NOTE="Dated columns: ${SHOWN_DATES} of ${NDATES} date(s) carrying worklog entries"
if [[ "$EARLIER_COL" == 1 ]]; then
  DAILY_NOTE+=", with the oldest dates folded into the \`≤ …\` column (raise --date-columns to spread them out)"
fi
DAILY_NOTE+=". A \`-\` cell means nothing was logged on that date for that issue."

# ---- 4. render report ---------------------------------------------------------
REPORT="/tmp/wlg.report.$$.md"
NPAGES=$(jq -r '(.data.items.sections.pages // [] | length)' "$WQ" 2>/dev/null || echo 0)
NPRS=$(jq -r '((.data.items.sections.pullRequests // []) + (.data.items.sections.reviewedPullRequests // []) | length)' "$WQ" 2>/dev/null || echo 0)
NCOM=$(jq -r '(.data.items.sections.comments // [] | length)' "$WQ" 2>/dev/null || echo 0)
WAIT="$(awk -F'\t' 'tolower($3) ~ /waiting|approv|review|blocked/ {printf "%s ", $1}' "$ISSUE_META" 2>/dev/null || true)"
INPROG="$(awk -F'\t' 'tolower($3) ~ /in progress/ {printf "%s ", $1}' "$ISSUE_META" 2>/dev/null || true)"
NNEW="$(awk -F'\t' -v w="$WINSTART" '$5 != "" && $5 >= w {printf "%s ", $1}' "$ISSUE_META" 2>/dev/null || true)"
NDONE="$(awk -F'\t' -v w="$WINSTART" '$7 != "" && $7 >= w {printf "%s ", $1}' "$ISSUE_META" 2>/dev/null || true)"

{
  echo "# Worklog Summary — ${WINDOW_LABEL}"
  echo ""
  echo "_Generated $(date '+%Y-%m-%d %H:%M') · scope: ${SCOPE} · source: TWG Teamwork Graph + Jira REST_"
  echo ""
  echo "## 📖 Standup summary"
  echo ""
  echo "- **Activity in window:** ${COUNTS}"
  echo "- **Time logged (Jira worklogs, in window):** $(fmt_dur "$TOTAL_SECS") across ${NTRACKED} tracked issue(s)."
  if (( NDATES > 0 )); then
    plural="entries"; [[ "$NWL" == 1 ]] && plural="entry"
    echo "- **Time logged (every dated worklog fetched, all-time):** $(fmt_dur "$TOTAL_SECS_ALL") across ${NWL} worklog ${plural} on ${NDATES} date(s)."
  fi
  [[ -n "$DAILY" ]] && echo "- **Daily logged time:** ${DAILY}"
  [[ -n "$WAIT" ]] && echo "- ⚠️ **Needs attention (waiting/blocked):** ${WAIT}"
  [[ -n "$INPROG" ]] && echo "- **In progress:** ${INPROG}"
  [[ -n "$NNEW" ]] && echo "- **Created in window:** ${NNEW}"
  [[ -n "$NDONE" ]] && echo "- ✅ **Completed in window:** ${NDONE}"
  (( NPAGES > 0 )) && echo "- **Documentation:** ${NPAGES} Confluence page(s) touched."
  (( NPRS > 0 )) && echo "- **Code:** ${NPRS} PR(s) authored/reviewed."
  (( NCOM > 0 )) && echo "- **Coordination:** ${NCOM} issue comment(s)."
  if [[ "$TOTAL_SECS" -eq 0 ]]; then
    echo "- ⚠️ **Tracking gap:** no Jira time entries logged in this window. Log retroactively with:"
    echo "  \`twg jira workitem worklog add --issue-id <KEY> --time-spent <e.g. 3h> --started <ISO8601> --comment \"...\"\`"
  fi
  echo ""
  echo "## 📊 Evidence table"
  echo ""
  if [[ -s "$ISSUE_META" ]]; then
    # One extra column per dated worklog entry (oldest dates collapse into "Earlier").
    awk -F'\t' -v site="$SITE_URL" -v dfile="$DATELIST" -v efile="$WL_ENTRIES" -v ws="$WINSTART" '
      function dur(s,   h, m) {            # compact cell form: 3h / 20m / 3h 20m
        s = int(s)
        if (s <= 0) return "-"
        h = int(s / 3600); m = int((s % 3600) / 60)
        if (h > 0 && m > 0) return h "h " m "m"
        if (h > 0) return h "h"
        return m "m"
      }
      function hhmm(s) { s = int(s); return int(s / 3600) "h " sprintf("%02dm", int((s % 3600) / 60)) }
      BEGIN {
        nd = 0
        while ((getline ln < dfile) > 0) { split(ln, a, "\t"); nd++; dd[nd] = a[1]; dl[nd] = a[2]; ds[nd] = a[3] + 0 }
        close(dfile)
        while ((getline ln < efile) > 0) {
          split(ln, a, "\t"); k = a[1]; d = a[2]; s = a[3] + 0; idx = 0
          for (i = 1; i <= nd; i++) if (dd[i] == d) { idx = i; break }
          if (idx == 0) continue
          if (ds[idx]) { cell[k, idx] += s; gcol[idx] += s } else { early[k] += s; gearly += s }
          if ((d "") >= (ws "")) { win[k] += s; gwin += s }
        }
        close(efile)
        # column list: oldest dates that do not fit collapse into a single "≤ MM-DD" column
        nhidden = 0
        for (i = 1; i <= nd; i++) if (!ds[i]) nhidden++
        nc = 0
        if (nhidden > 0) { nc++; colsrc[nc] = 0; collab[nc] = "≤ " dl[nhidden]; colhide[nc] = 1 }
        for (i = nhidden + 1; i <= nd; i++) { nc++; colsrc[nc] = i; collab[nc] = dl[i]; colhide[nc] = 0 }
        hdr = "| Issue | Summary | Status | Created | Updated | Completed | Logged (window) | Logged (all-time) |"
        sep = "|---|---|---|---|---|---|---|---|"
        for (j = 1; j <= nc; j++) { hdr = hdr " " collab[j] " |"; sep = sep "---|" }
        print hdr; print sep
      }
      {
        k = $1; summ = $2; st = $3; life = $4 + 0
        gsub(/\|/, "\\|", summ)
        marker = ""
        if (tolower(st) ~ /waiting|approv|review|blocked/) marker = " ⚠️"
        alllife += life
        row = "| [" k "](" site "/browse/" k ") | " summ " | " st marker " | "
        row = row ($5 == "" ? "-" : $5) " | " ($6 == "" ? "-" : $6) " | " ($7 == "" ? "-" : $7) " | "
        row = row hhmm(win[k]) " | " hhmm(life) " |"
        for (j = 1; j <= nc; j++) row = row " " (colhide[j] ? dur(early[k]) : dur(cell[k, colsrc[j]])) " |"
        print row
      }
      END {
        if (NR > 0 && nc > 0) {
          row = "| **Daily total** | | | | | | **" hhmm(gwin) "** | **" hhmm(alllife) "** |"
          for (j = 1; j <= nc; j++) row = row " **" (colhide[j] ? dur(gearly) : dur(gcol[colsrc[j]])) "** |"
          print row
        }
      }
    ' "$ISSUE_META"
  else
    echo "_No Jira issues matched in this window._"
  fi
  if (( NDATES > 0 )); then
    echo ""
    echo "_${DAILY_NOTE}_"
  fi
  if (( NPAGES > 0 )); then
    echo ""
    echo "### Pages touched"
    jq -r '.data.items.sections.pages[]? | "- " + (.title // .id // "untitled")' "$WQ" 2>/dev/null
  fi
  if (( NCOM > 0 )); then
    echo ""
    echo "### Comments"
    jq -r '.data.items.sections.comments[]? | "- " + ((.created // "?") | split("T")[0]) + " → " + (.webUrl // .id // "")' "$WQ" 2>/dev/null
  fi
  echo ""
  echo "## Confidence & coverage"
  echo ""
  echo "- Issue/comment counts come from the Teamwork Graph (\`coverage: partial\`); zero PR/meeting rows may mean *unindexed*, not *unworked*."
  echo "- 'Logged (all-time)' is Jira native \`timespent\`; Tempo or other timers are not included."
  echo "- Dated columns come from each worklog entry's \`started\` timestamp, so an entry added today or yesterday lands in its own column."
  if (( DATE_COLS > 0 )); then
    echo "- Worklogs are fetched for **every date ever logged** on each issue (no window filter); the ${DATE_COLS} most recent dated logs get their own columns and anything older folds into the \`≤ …\` column (use \`--date-columns 0\` to give every dated log its own column)."
  else
    echo "- Worklogs are fetched for **every date ever logged** on each issue (no window filter); every dated log gets its own column."
  fi
} > "$REPORT"

cat "$REPORT"
if [[ -n "$OUT" ]]; then cp "$REPORT" "$OUT"; echo ">> report written to $OUT" >&2; fi
rm -f "$ISSUE_META" "$WL_ENTRIES" "$DATES_ALL" "$DATELIST" "$REPORT"

