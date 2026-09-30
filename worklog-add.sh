#!/usr/bin/env bash
# worklog-add.sh — batch-log time entries to Jira via twg (write tool).
#
# Usage:
#   ./worklog-add.sh [options] "KEY TIME [DATE] [comment...]" ...
#   ./worklog-add.sh [options] -f entries.txt
#
# Entry syntax (one per quoted argument or per line in -f file):
#   DEMO-421 3h 2026-09-21 Data flow design          full form
#   PILOT-18926 90m                                    defaults: today, generic comment
#   INFRA-5321 1h30m 2026-09-18                     compact duration + date only
#   https://jira.example.com/browse/DEMO-421 3h Data flow   Jira link instead of key
#   DEMO-421 45m today / yesterday                                relative date words
#   DEMO-435 1h 51m yesterday Data flow                spaced multi-unit duration
#   https://jira.example.com/browse/DEMO-421 3h Data flow   Jira link instead of key
#   DEMO-421 1h 2026-09-21 op:65:Support #data doc    op: tag -> OpenProject sync (see below)
#
# OpenProject tag: the entry grammar is 'KEY DURATION [DATE] op:<wp_id>[:<activity>] COMMENT'
# — the COMMENT is ALWAYS the LAST part of the line. The op: tag only counts in
# that fixed position (right after the duration and optional date); it is never
# logged to Jira and never changes the entry fingerprint, so adding/changing a
# tag on an already-logged line does NOT re-log it. Words that merely look like
# 'op:...' inside the comment (after the tag position) stay in the comment.
# Lines starting with '#' and blank lines in -f files are ignored.
#
# Duration: 3h | 90m | 1h30m | 1h 30m | 0.5d | 2w — always converted to exact
# seconds and sent as --time-spent-seconds (Jira rejects the unspaced '1h51m'
# string form). Day = 8h and week = 40h when those units are used.
#
# Issue ref: a bare key (DEMO-421 / demo-421) or any Jira link containing one —
# /browse/KEY, /jira/.../issues/KEY, /task/KEY, Markdown links like
# [DEMO-421](https://.../browse/DEMO-421), and links with ?focusedCommentId=...,
# ?selectedIssue=... or #fragment suffixes. The key is resolved from the link;
# everything else about the entry is unchanged.
# Confluence links (/wiki/spaces/…/pages/…, /display/…) are NOT issue refs —
# the entry must start with the Jira key and the Confluence link goes in the
# comment position, after the duration (and optional date). It is logged to
# Jira verbatim as part of the comment and covered by entry tracking:
#   DEMO-421 1h Today Design doc: https://site/wiki/spaces/INF/pages/123/Page
#
# Options:
#   --dry-run       Print the exact twg commands and exit (no writes)
#   --yes           Skip interactive confirmation (required for non-TTY use)
#   --at HH:MM      Default start time on the date (default: 09:00)
#   --tz +0800      Timezone offset appended to plain dates (default: +0800)
#   --notify-false  Pass --notify-users false (suppress Jira notifications)
#   --state FILE    Tracking file for already-logged entries (default:
#                   ~/.config/worklog-add/logged.log, or env WORKLOG_ADD_STATE)
#   --force         Ignore the tracking file and log every entry again
#   -f FILE         Read entries from FILE
#   -h, --help      Show this help
#
# Tracking: every entry is fingerprinted (its line uppercased and whitespace-
# squeezed, SHA-256 hashed) and the fingerprint is appended to the state file
# once the worklog logs successfully. Re-runs skip entries whose fingerprint is
# already tracked, so you can keep appending new lines to a file like `entries`
# and run the script again: only the untracked items get logged. Use --force to
# log everything regardless, or delete a line from the state file to re-enable
# one entry. Note the fingerprint tracks the entry text, not the Jira worklog:
# an entry written as "... Today" logged yesterday is still "tracked" today.
# The op: OpenProject tag in its position is excluded from the fingerprint, so
# adding or changing a tag on a line never makes it re-log to Jira.
#
# Safety: shows a plan + before-snapshot, asks for confirmation, executes,
# then verifies each issue's total timespent delta against the seconds written.

set -euo pipefail

# twg is located now but required only when something actually executes:
# --help and --dry-run work without it (the CI smoke tests depend on that).
if command -v twg >/dev/null 2>&1; then TWG="twg"
elif [[ -x "$HOME/.local/bin/twg" ]]; then TWG="$HOME/.local/bin/twg"
else TWG=""; fi
require_twg() { [[ -n "$TWG" ]] || { echo "twg not found on PATH or ~/.local/bin" >&2; exit 1; }; }

# Print the leading comment block (line 2 up to the first non-comment line).
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }

DRY=0; ASSUME_YES=0; AT="09:00"; TZOFF="+0800"; NOTIFY=""; FILE=""; ENTRIES=()
FORCE=0; STATE="${WORKLOG_ADD_STATE:-$HOME/.config/worklog-add/logged.log}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY=1; shift;;
    --yes)         ASSUME_YES=1; shift;;
    --at)          AT="$2"; shift 2;;
    --tz)          TZOFF="$2"; shift 2;;
    --notify-false) NOTIFY="--notify-users false"; shift;;
    --state)       STATE="$2"; shift 2;;
    --force)       FORCE=1; shift;;
    -f)            FILE="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    -*)            echo "unknown option: $1" >&2; exit 1;;
    *)             ENTRIES+=("$1"); shift;;
  esac
done

if [[ -n "$FILE" ]]; then
  [[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    ENTRIES+=("$line")
  done < "$FILE"
fi
[[ ${#ENTRIES[@]} -gt 0 ]] || { echo "no entries given (see --help)" >&2; usage; exit 1; }
[[ "$AT" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || { echo "--at must be HH:MM" >&2; exit 1; }
[[ "$TZOFF" =~ ^[+-][0-9]{4}$ ]] || { echo "--tz must be like +0800" >&2; exit 1; }

# ---- tracking state file ------------------------------------------------------
# Prepared early; a failure here only degrades tracking to a warning, it does
# not stop logging (writes to the file happen only after a successful log).
TRACK_OK=1
if ! mkdir -p "$(dirname "$STATE")" 2>/dev/null && [[ ! -d "$(dirname "$STATE")" ]]; then
  echo "(warning: cannot create state dir for $STATE — tracking disabled)" >&2; TRACK_OK=0
elif [[ ! -f "$STATE" ]] && ! : >> "$STATE" 2>/dev/null; then
  echo "(warning: cannot write state file $STATE — tracking disabled)" >&2; TRACK_OK=0
fi

# ---- resolve a Jira issue key from a bare key or a link -------------------------
# Accepts: DEMO-421 | demo-421 | https://site/browse/DEMO-421 | .../jira/software/311/
# boards/527/issues/DEMO-421 | .../si/task/DEMO-421 | [DEMO-421](https://site/browse/
# DEMO-421) | .../browse/DEMO-421?focusedCommentId=1536950 | ...?selectedIssue=DEMO-421
# Prints the uppercased key; returns 1 when no key can be found.
extract_key() {
  local tok="$1" nohash path key=""
  [[ -n "$tok" ]] || return 1
  # 1) bare key, any case
  if [[ "$tok" =~ ^[A-Za-z][A-Za-z0-9]+-[0-9]+$ ]]; then
    printf '%s\n' "$tok" | tr '[:lower:]' '[:upper:]'
    return 0
  fi
  # 2) link: drop the #fragment, then the scheme+host of every URL in the token so a
  #    hyphenated host (acme-123.atlassian.net) can never be read as a key. The query
  #    string is kept (?selectedIssue=KEY) and a Markdown label ([KEY](...)) survives.
  nohash="${tok%%#*}"
  path="$(printf '%s' "$nohash" | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*/##')"
  # 2b) Confluence links (/wiki/spaces/…, /spaces/…/pages/…, /display/…) carry no
  #     Jira key — their page slugs (…/Data-Architecture-2026) would be misread as
  #     keys by the fallbacks below. Reject them here: the Jira key must come first
  #     and the Confluence link belongs in the comment position. Exception: a
  #     Markdown label carrying a real key, [DEMO-421](https://site/wiki/...), is
  #     an explicit reference and still resolves to the label key below.
  if [[ "$path" == wiki/* || "$path" == display/* || "$path" == */display/* || ("$path" == */spaces/* && "$path" == */pages/*) ]] \
     && ! [[ "$path" =~ \[[A-Za-z][A-Za-z0-9]+-[0-9]+\]\( ]]; then
    return 1
  fi
  # 3) key taken from a known Jira path marker (query string ignored here)
  key="$(printf '%s' "${path%%\?*}" | sed -nE \
    's#.*(browse|browseissues|issues|issue|task|selected|backlog|allissues|version|filter)/([A-Za-z][A-Za-z0-9]+)-([0-9]+).*#\2-\3#Ip' \
    | tail -1 || true)"
  # 4) fallback: leftmost KEY-123 shaped substring left in the link
  [[ -n "$key" ]] || key="$(printf '%s' "$path" | grep -oE '[A-Za-z][A-Za-z0-9]+-[0-9]+' | head -1 || true)"
  [[ -n "$key" ]] || return 1
  printf '%s\n' "$key" | tr '[:lower:]' '[:upper:]'
}

# 1h51m / 1h 51m / 90m / 3h / 0.5d / 2w -> integer seconds (day = 8h, week = 40h).
dur_to_seconds() {
  awk -v d="$1" 'BEGIN {
    hpday = 28800; total = 0; s = d
    while (match(s, /^[0-9]+([.][0-9]+)?[wdhm]/)) {
      t = substr(s, RSTART, RLENGTH); u = substr(t, length(t), 1); v = substr(t, 1, length(t) - 1) + 0
      if (u == "h") total += v * 3600
      else if (u == "m") total += v * 60
      else if (u == "d") total += v * hpday
      else total += v * 5 * hpday
      s = substr(s, RLENGTH + 1)
    }
    printf "%d\n", total + 0.5
  }'
}

# seconds -> "1h 51m" (display only)
hms() { printf '%dh %02dm' $((${1:-0}/3600)) $(((${1:-0}%3600)/60)); }

# Entry fingerprint: SHA-256 of the entry line uppercased with all runs of
# whitespace squeezed to single spaces (so 'demo-421 1h today' and
# 'DEMO-421   1H  Today' track as the same entry regardless of key case).
hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}
entry_fingerprint() {
  printf '%s\n' "$1" | awk '{ $1=$1; print toupper($0) }' | hash_stdin
}
# State file lines are "<sha256>\t<KEY>" (key kept for human readability).
is_tracked() {
  [[ -f "$STATE" ]] || return 1
  awk -v f="$1" '$1==f{found=1} END{exit !found}' "$STATE" 2>/dev/null
}

# ---- parse entries ------------------------------------------------------------
K=(); D=(); S=(); C=(); X=(); FP=()   # key, raw duration, started, comment, duration seconds, fingerprint
TODAY="$(date +%F)"
YESTERDAY="$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F)"
n=0; SKIPC=0
for e in "${ENTRIES[@]}"; do
  n=$((n+1))
  set -f; set -- $e; set +f   # -f: URLs carry glob chars (?, *) that must stay literal
  # ---- locate the OpenProject tag in its fixed position -------------------------
  # Grammar: KEY DURATION [DATE] op:<wp>[:<activity>] COMMENT — the comment is
  # the LAST part of the line, so an op: token only counts as the tag when it
  # sits right after the duration (and optional date). The scan below mirrors
  # the parser: split durations ("1h 30m") and dates (ISO | today | yesterday)
  # are consumed first; whatever remains from the tag token onward is comment.
  full=("$@"); tagi=""; c=2
  if [[ ${#full[@]} -ge 3 && "${full[1]}" =~ ^[0-9]+([.][0-9]+)?[wdhm]$ && "${full[2]}" =~ ^[0-9]+[wdhm]$ ]]; then c=3; fi
  if [[ $c -lt ${#full[@]} ]]; then
    cand="${full[$c]}"; cand_lc="$(printf '%s' "$cand" | tr '[:upper:]' '[:lower:]')"
    if [[ "$cand" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T.*)?$ || "$cand_lc" == "today" || "$cand_lc" == "yesterday" ]]; then c=$((c+1)); fi
    [[ $c -lt ${#full[@]} && "${full[$c]}" =~ ^[Oo][Pp]: ]] && tagi=$c
  fi
  # fingerprint source = the raw line WITHOUT the tag token, so adding or
  # editing a tag never changes the fingerprint (no accidental re-logs).
  if [[ -n "$tagi" ]]; then
    e_fp=""
    for ((j=0; j<${#full[@]}; j++)); do [[ $j -ne $tagi ]] && e_fp+=" ${full[$j]}"; done
  else
    e_fp="$e"
  fi
  ref="${1:-}"; dur="${2:-}"
  key="$(extract_key "$ref")" \
    || { echo "entry $n: no Jira issue key in '$ref' — put the Jira key (or a Jira link) first; Confluence links belong in the comment, after the duration (see --help)" >&2; exit 1; }
  [[ "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "entry $n: bad issue key '$key'" >&2; exit 1; }
  # duration: one token ("1h30m", "90m", "0.5d") or two spaced tokens ("1h 30m")
  if [[ "$dur" =~ ^[0-9]+([.][0-9]+)?[wdhm]$ && "${3:-}" =~ ^[0-9]+[wdhm]$ ]]; then
    dur="$dur$3"; shift 3
  else
    shift 2
  fi
  [[ "$dur" =~ ^[0-9]+([.][0-9]+)?[wdhm]([0-9]+[wdhm])*$ ]] \
    || { echo "entry $n: bad duration '$dur' (use 3h / 90m / 1h30m / 1h 30m / 0.5d / 2w)" >&2; exit 1; }
  secs="$(dur_to_seconds "$dur")"
  [[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]] \
    || { echo "entry $n: duration '$dur' resolves to zero seconds" >&2; exit 1; }
  # optional date token (YYYY-MM-DD | ISO timestamp | today | yesterday), rest = comment
  date_tok=""; low="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T.*)?$ ]]; then
    date_tok="$1"; shift
  elif [[ "$low" == "today" || "$low" == "yesterday" ]]; then
    if [[ "$low" == "today" ]]; then date_tok="$TODAY"; else date_tok="$YESTERDAY"; fi
    shift
  fi
  # consume the op: tag when the scan above found it in position; the rest is
  # the comment — the comment is ALWAYS the last part of the entry line.
  [[ -n "$tagi" ]] && shift
  comment="$*"
  if [[ -z "$date_tok" ]]; then started="${TODAY}T${AT}:00.000${TZOFF}"
  elif [[ "$date_tok" == *T* ]]; then started="$date_tok"
  else started="${date_tok}T${AT}:00.000${TZOFF}"; fi
  [[ -n "$comment" ]] || comment="Time logged via worklog-add.sh"
  # tracking: skip entries already logged on a previous run (unless --force)
  fp="$(entry_fingerprint "$e_fp")"
  if [[ $FORCE -ne 1 && $TRACK_OK -eq 1 ]] && is_tracked "$fp"; then
    echo "  [skip] entry $n already logged: $key $(hms "$secs") \"$comment\"  (tracked in $STATE)"
    SKIPC=$((SKIPC+1)); continue
  fi
  FP+=("$fp"); K+=("$key"); D+=("$dur"); S+=("$started"); C+=("$comment"); X+=("$secs")
done
[[ ${#K[@]} -gt 0 ]] || { echo "== Nothing to log: $SKIPC of $n entries already tracked in $STATE (use --force to log again) =="; exit 0; }

# ---- preview plan --------------------------------------------------------------
echo "== Planned worklogs (${#K[@]} entries) =="
(( SKIPC > 0 )) && echo "  ($SKIPC already-logged $([ "$SKIPC" -eq 1 ] && echo "entry skipped" || echo "entries skipped") — tracked in $STATE)"
for i in "${!K[@]}"; do
  echo "  ${K[$i]}  ${D[$i]} = $(hms "${X[$i]}")  started=${S[$i]}  \"${C[$i]}\""
  echo "    \$ $TWG jira workitem worklog add --issue-id ${K[$i]} --time-spent-seconds ${X[$i]} --started '${S[$i]}' --comment '${C[$i]}' --comment-format plain $NOTIFY"
done
[[ $DRY -eq 1 ]] && { echo "(dry-run: nothing written)"; exit 0; }
require_twg   # only real executions need twg — help/dry-run stay dependency-free

# ---- confirm --------------------------------------------------------------------
if [[ $ASSUME_YES -ne 1 ]]; then
  if [[ -t 0 ]]; then
    printf "Write these %s worklog(s) to Jira? [y/N] " "${#K[@]}"
    read -r ans; [[ "$ans" == [yY]* ]] || { echo "aborted, nothing written"; exit 1; }
  else
    echo "refusing to write without --yes in a non-interactive shell" >&2; exit 1
  fi
fi

# ---- helper: run twg, echo raw JSON file path ------------------------------------
run_twg() {
  local env errf line p raw
  errf="$(mktemp /tmp/wla.err.XXXXXX)"
  env="$("$TWG" "$@" --output json 2>"$errf")" || true
  line="$(printf '%s\n' "$env" | grep -m1 -E '^[[:space:]]*stdout:' || true)"
  [[ -z "$line" ]] && line="$(printf '%s\n' "$env" | grep -m1 -E '^[[:space:]]*compact:' || true)"
  p="$(printf '%s\n' "$line" | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')"
  if [[ -n "$p" && -f "$p" ]]; then rm -f "$errf"; printf '%s\n' "$p"; return 0; fi
  if [[ -n "$env" && "${env:0:1}" == "{" ]]; then
    raw="$(mktemp /tmp/wla.raw.XXXXXX)" || raw=""
    if [[ -n "$raw" ]] && printf '%s\n' "$env" > "$raw"; then rm -f "$errf"; printf '%s\n' "$raw"; return 0; fi
    rm -f "$raw"
  fi
  { echo "--- twg failed: $* ---" >&2; [[ -s "$errf" ]] && head -5 "$errf" >&2; }
  rm -f "$errf"; return 1
}

# twg's "jira workitem get" returns .data as an ARRAY for a single issue but
# .data.items[] (wrapped in {input, ok, data}) for a batch — handle both shapes.
TIMESPENT_JQ='if (.data | type) == "array" then
                (.data[] | select(type == "object")
                 | [ .key, ((.timespent // 0) | floor | tostring) ] | @tsv)
              elif (.data | type) == "object" and ((.data.items | type) == "array") then
                (.data.items[] | select(.ok) | .data
                 | [ .key, ((.timespent // 0) | floor | tostring) ] | @tsv)
              else empty end'

# ---- before snapshot (one batched read) -------------------------------------------
UKEYS="$(printf '%s\n' "${K[@]}" | sort -u)"
BEFORE="/tmp/wla.before.$$.tsv"; AFTER="/tmp/wla.after.$$.tsv"; EXPECTED="/tmp/wla.expect.$$.tsv"
: > "$BEFORE"; : > "$AFTER"
for i in "${!K[@]}"; do printf '%s\t%s\n' "${K[$i]}" "${X[$i]}"; done \
  | awk -F'\t' '{a[$1]+=$2} END{for (k in a) printf "%s\t%d\n", k, a[k]}' > "$EXPECTED"
if GF="$(run_twg jira workitem get $UKEYS --fields timespent)"; then
  jq -r "$TIMESPENT_JQ" "$GF" > "$BEFORE" 2>/dev/null || true
  [[ -s "$BEFORE" ]] || echo "(warning: before-snapshot is empty; verification will be limited)" >&2
else
  echo "(warning: before-snapshot failed; verification will be limited)" >&2
fi

# ---- execute ------------------------------------------------------------------------
RUNLOG="$(mktemp -d /tmp/wla.run.XXXXXX)"
OKC=0; FAILC=0; FAILED=()
for i in "${!K[@]}"; do
  printf '>>> logging %s %s (%s) ... ' "${K[$i]}" "$(hms "${X[$i]}")" "${S[$i]}"
  out="$RUNLOG/${K[$i]}.$i.log"
  # shellcheck disable=SC2086
  if "$TWG" jira workitem worklog add --issue-id "${K[$i]}" --time-spent-seconds "${X[$i]}" \
       --started "${S[$i]}" --comment "${C[$i]}" --comment-format plain $NOTIFY >"$out" 2>&1; then
    echo "ok"; OKC=$((OKC+1))
    # track success only after the worklog actually landed (idempotent: --force
    # runs re-log without duplicating state lines)
    if [[ $TRACK_OK -eq 1 ]] && ! is_tracked "${FP[$i]}"; then
      printf '%s\t%s\n' "${FP[$i]}" "${K[$i]}" >> "$STATE" 2>/dev/null \
        || echo "    (warning: could not write tracking state to $STATE)" >&2
    fi
  else
    echo "FAILED"; FAILC=$((FAILC+1)); FAILED+=("${K[$i]} $(hms "${X[$i]}")")
    why="$(grep -m1 -E '^Error:' "$out" 2>/dev/null | cut -c1-220)"
    [[ -n "$why" ]] || why="$(head -4 "$out" 2>/dev/null | tr '\n' ' ' | cut -c1-220)"
    printf '    reason: %s\n' "${why:-no message captured, see $out}"
  fi
done

# ---- verify (batched diff) --------------------------------------------------------------
echo ""
if [[ -s "$BEFORE" ]] && GF="$(run_twg jira workitem get $UKEYS --fields timespent)"; then
  jq -r "$TIMESPENT_JQ" "$GF" > "$AFTER" 2>/dev/null || true
  echo "== Verification: total timespent per issue (before -> after) =="
  while IFS=$'\t' read -r k b; do
    a="$(awk -F'\t' -v k="$k" '$1==k{print $2}' "$AFTER")"; a="${a:-$b}"
    e="$(awk -F'\t' -v k="$k" '$1==k{print $2}' "$EXPECTED")"; e="${e:-0}"
    verdict="OK"; [[ $((a-b)) -eq $e ]] || verdict="MISMATCH"
    printf '  %-14s %s -> %s  +%s (expected +%s)  %s\n' \
      "$k" "$(hms "$b")" "$(hms "$a")" "$(hms "$((a-b))")" "$(hms "$e")" "$verdict"
  done < "$BEFORE"
else
  echo "(verification snapshot unavailable — check the issues manually)" >&2
fi

echo ""
echo "== Done: $OKC logged, $FAILC failed, $SKIPC already tracked =="
[[ $FAILC -gt 0 ]] && { printf 'failed: %s\n' "${FAILED[*]}" >&2
                        echo "raw twg output kept in $RUNLOG" >&2; exit 2; }
exit 0