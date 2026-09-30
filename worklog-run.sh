#!/usr/bin/env bash
# worklog-run.sh — one file, one command: log the worklog to Jira AND sync the
# OpenProject-mapped items. Maintains a SINGLE file (`entries`); the old
# op-mapping.tsv is no longer needed — the mapping lives inline as op: tags.
#
# Usage:
#   OP_BASE_URL=https://op.example.com OP_TOKEN=xxx ./worklog-run.sh [options]
#
# The entries file (default: `entries` next to this script), one entry per line:
#   KEY DURATION [DATE] op:<wp_id>[:<activity>] COMMENT
# The COMMENT is always the LAST part of the line; the op: tag must sit right
# before it (after the duration and optional date).
#
#   * line WITHOUT an op: tag    -> logged to Jira only (untracked lines are
#                                   skipped once logged; worklog-add.sh state)
#   * op:<wp_id>                 -> the entry's key is ALSO mirrored to that
#                                   OpenProject work package as a time entry
#   * op:<wp_id>:<activity>      -> OP activity by name (use '+' for spaces,
#                                   e.g. op:448:Design+(Solutioning)) or by
#                                   numeric id (op:448:4). Omit = server default
#
# The op: tag never reaches the Jira comment and does not change the logged-entry
# fingerprint — tagging an already-logged line only (re)plans the OP sync.
# Words inside the COMMENT that merely look like 'op:...' stay in the comment.
#
# What it does on every run (both phases idempotent, re-runs are safe):
#   Phase 1  worklog-add.sh -f entries   -> logs every NOT-yet-tracked line to Jira
#   Phase 2  op-sync.sh --mapping <map>  -> mirrors the last WEEKS of Jira
#            worklogs of the op:-tagged keys to OpenProject (deduped via
#            ~/.config/op-sync/synced.log)
#
# Options:
#   -f FILE          entries file (default: $WORKLOG_ENTRIES, else ./entries in
#                    the cwd, else ~/.config/worklog/entries, else `entries`
#                    next to this script)
#   --weeks N        OpenProject sync window in weeks (default: 1)
#   --jira-only      phase 1 only (no OpenProject credentials needed)
#   --op-only        phase 2 only
#   --dry-run        both phases show what they would do; nothing is written
#   --yes            skip the Jira confirmation prompt (required in non-TTY)
#   --force          re-log every entry to Jira (creates new worklogs -> also
#                    new OpenProject entries). Use sparingly.
#   --print-map      show the generated Jira->OpenProject mapping table and exit
#   --at HH:MM       default start time        (forwarded to worklog-add.sh)
#   --tz +0800       timezone offset           (forwarded to worklog-add.sh)
#   --state FILE     Jira tracking state file  (forwarded to worklog-add.sh)
#   --notify-false   suppress Jira notifications (forwarded to worklog-add.sh)
#   --author EMAIL   only sync this OP author   (forwarded to op-sync.sh)
#   --auto-lookup    resolve unmapped WP ids by OP subject search (op-sync.sh)
#   --list-wps [N]   list OpenProject work packages (ids to use in op: tags)
#                    and exit — no entries file needed (forwarded to op-sync)
#   --wp-filter STR  with --list-wps: only WPs whose subject contains STR
#   --list-activities
#                    list OpenProject time-entry activities (the names/ids for
#                    the op:<wp_id>:<activity> suffix) and exit — no entries
#                    file needed (forwarded to op-sync)
#   --url URL        override OP_BASE_URL       (forwarded to op-sync.sh)
#   --token TOK      override OP_TOKEN          (forwarded to op-sync.sh)
#   -h, --help       show this help
#
# Environment: OP_BASE_URL / OP_TOKEN for phase 2 (same as op-sync.sh);
# OP_SYNC_STATE / WORKLOG_ADD_STATE to relocate either state file.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Resolve a sibling tool across install layouts: a repo checkout keeps the .sh
# filenames, a brew install strips them (bin/worklog-add, bin/op-sync), and PATH
# is the last resort. Echoes an executable path or fails with a clear message.
locate_tool() { # $1=basename with .sh
  local s="$1"
  [[ -x "$HERE/$s" ]] && { printf '%s' "$HERE/$s"; return 0; }
  [[ -x "$HERE/${s%.sh}" ]] && { printf '%s' "$HERE/${s%.sh}"; return 0; }
  command -v "${s%.sh}" 2>/dev/null && return 0
  echo "cannot find ${s%.sh} (looked: $HERE/$s, $HERE/${s%.sh}, PATH)" >&2
  return 1
}

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }

FILE="${WORKLOG_ENTRIES:-}"; WEEKS=1
DRY=0; YES=0; FORCE=0; JIRA_ONLY=0; OP_ONLY=0; PRINT_MAP=0
AUTOLOOK=0; AUTHOR=""; OPURL=""; OPTOK=""
LISTWPS=0; LISTN=""; WPFILT=""; LISTACTS=0
ADD_EXTRA=()          # options forwarded verbatim to worklog-add.sh
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)             FILE="$2"; shift 2;;
    --weeks)        WEEKS="$2"; shift 2;;
    --jira-only)    JIRA_ONLY=1; shift;;
    --op-only)      OP_ONLY=1; shift;;
    --dry-run)      DRY=1; shift;;
    --yes)          YES=1; shift;;
    --force)        FORCE=1; shift;;
    --print-map)    PRINT_MAP=1; shift;;
    --at|--tz|--state) ADD_EXTRA+=("$1" "$2"); shift 2;;
    --notify-false) ADD_EXTRA+=("$1"); shift;;
    --author)       AUTHOR="$2"; shift 2;;
    --auto-lookup)  AUTOLOOK=1; shift;;
    --list-wps)     LISTWPS=1
                    if [[ ${2:-} =~ ^[0-9]+$ ]]; then LISTN="$2"; shift 2; else shift; fi;;
    --wp-filter)    WPFILT="$2"; shift 2;;
    --list-activities) LISTACTS=1; shift;;
    --url)          OPURL="$2"; shift 2;;
    --token)        OPTOK="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *)              echo "unknown option: $1" >&2; usage >&2; exit 1;;
  esac
done
[[ "$WEEKS" =~ ^[0-9]+$ && "$WEEKS" -ge 1 ]] || { echo "--weeks must be a positive integer" >&2; exit 1; }

# ---- list mode: browse OpenProject work packages, then exit ---------------------
# Runs before entries-file resolution: choosing a WP id should work even in a
# fresh folder with no entries file yet. Credentials/URL flags are forwarded.
if [[ $LISTWPS -eq 1 ]]; then
  SYNC_BIN="$(locate_tool op-sync.sh)" || exit 1
  S=(--list-wps)
  [[ -n "$LISTN"  ]] && S+=("$LISTN")
  [[ -n "$WPFILT" ]] && S+=(--wp-filter "$WPFILT")
  [[ -n "$OPURL"  ]] && S+=(--url "$OPURL")
  [[ -n "$OPTOK"  ]] && S+=(--token "$OPTOK")
  exec "$SYNC_BIN" "${S[@]}"
fi

# ---- list mode: browse OpenProject activities, then exit -----------------------
# Same contract as --list-wps: runs before entries-file resolution and forwards
# the credential flags; needs no twg, no mapping, no Jira read.
if [[ $LISTACTS -eq 1 ]]; then
  SYNC_BIN="$(locate_tool op-sync.sh)" || exit 1
  S=(--list-activities)
  [[ -n "$OPURL" ]] && S+=(--url "$OPURL")
  [[ -n "$OPTOK" ]] && S+=(--token "$OPTOK")
  exec "$SYNC_BIN" "${S[@]}"
fi

# ---- entries file resolution ---------------------------------------------------
# Order: -f FILE  >  $WORKLOG_ENTRIES  >  ./entries (cwd)  >  ~/.config/worklog/
# entries  >  the legacy copy next to this script. The cwd/home defaults are what
# make a brew-installed worklog-run (which lives in /opt/homebrew/bin, next to no
# data file) usable from anywhere.
if [[ -z "$FILE" ]]; then
  for cand in "$PWD/entries" "$HOME/.config/worklog/entries" "$HERE/entries"; do
    [[ -f "$cand" ]] && { FILE="$cand"; break; }
  done
  [[ -n "$FILE" ]] || { echo "no entries file found: pass -f FILE, or export WORKLOG_ENTRIES, or create ~/.config/worklog/entries" >&2; exit 1; }
fi
[[ -f "$FILE" ]] || { echo "entries file not found: $FILE" >&2; exit 1; }
if [[ $JIRA_ONLY -eq 1 && $OP_ONLY -eq 1 ]]; then echo "--jira-only and --op-only are mutually exclusive" >&2; exit 1; fi
# ---- build the OpenProject mapping from the op: tags in the entries file -------
# Output rows:  KEY<TAB>wp_id<TAB>activity   (op-sync.sh --mapping dialect).
# Comment lines (#) and blank lines are skipped; first mapping row per key wins.
MAP="$(mktemp /tmp/wrun.map.XXXXXX)"
trap 'rm -f "$MAP"' EXIT
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"                       # ltrim
  [[ -z "$line" || "$line" == \#* ]] && continue
  # The op: tag counts only in its fixed position — after the duration and
  # optional date, before the comment (the comment is the LAST part of the
  # line): KEY=$1 DUR=$2 [+3 when split like "1h 30m"] [DATE] [TAG] COMMENT...
  tag="$(awk '{
      if (NF < 2) next
      p = 3
      if (NF >= 4 && $2 ~ /^[0-9]+([.][0-9]+)?[wdhm]$/ && $3 ~ /^[0-9]+[wdhm]$/) p = 4
      if (NF >= p + 1) { d = $p
        if (d ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}(T.*)?$/ || tolower(d) == "today" || tolower(d) == "yesterday") p++ }
      if (NF >= p && $p ~ /^[Oo][Pp]:/) print $p
    }' <<<"$line")"
  if [[ -z "$tag" ]]; then
    grep -qiE '(^|[[:space:]])op:' <<<"$line" \
      && echo "  ! misplaced op: tag (must sit BEFORE the comment, after the date): $line" >&2
    continue
  fi
  val="${tag#*:}"                                               # drop the 'op' prefix
  wp="${val%%:*}"; act=""
  [[ "$val" == *:* ]] && act="${val#*:}"
  act="${act//+/ }"; act="${act%"${act##*[![:space:]]}"}"       # '+'->space, rtrim
  key="$(awk '{print $1}' <<<"$line")"
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]+-[0-9]+$ ]] \
    || key="$(grep -oE '[A-Za-z][A-Za-z0-9]+-[0-9]+' <<<"$line" | head -1 || true)"
  [[ -n "$key" ]] || { echo "  ! skipping line without a Jira key: $line" >&2; continue; }
  [[ "$wp" =~ ^[0-9]+$ ]] || { echo "  ! bad op: tag on line (wp id must be numeric): $line" >&2; continue; }
  printf '%s\t%s\t%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$key")" "$wp" "$act"
done < "$FILE" | awk -F'\t' '!seen[$1]++' > "$MAP"

if [[ $PRINT_MAP -eq 1 ]]; then
  echo "== Generated OpenProject mapping (KEY -> WP id, activity) =="
  if [[ -s "$MAP" ]]; then column -t -s $'\t' < "$MAP"; else echo "  (no op:-tagged entries in $FILE)"; fi
  exit 0
fi

RC=0

# ---- phase 1: Jira ---------------------------------------------------------------
if [[ $OP_ONLY -eq 0 ]]; then
  echo "==> Phase 1/2 — Jira: logging untracked entries from $FILE"
  ADD_BIN="$(locate_tool worklog-add.sh)" || exit 1
  A=(-f "$FILE")
  [[ $DRY   -eq 1 ]] && A+=(--dry-run)
  [[ $YES   -eq 1 ]] && A+=(--yes)
  [[ $FORCE -eq 1 ]] && A+=(--force)
  set +e
  "$ADD_BIN" "${A[@]}" ${ADD_EXTRA[@]+"${ADD_EXTRA[@]}"}
  rc1=$?
  set -e
  if [[ $rc1 -ne 0 ]]; then
    echo "  ! phase 1 exited $rc1 — continuing with OpenProject sync of what is in Jira" >&2
    RC=$rc1
  fi
else
  echo "==> Phase 1/2 — skipped (--op-only)"
fi

# ---- phase 2: OpenProject ----------------------------------------------------------
if [[ $JIRA_ONLY -eq 0 ]]; then
  if [[ -s "$MAP" ]]; then
    echo "==> Phase 2/2 — OpenProject: syncing mapped keys (${WEEKS} week window)"
    SYNC_BIN="$(locate_tool op-sync.sh)" || exit 1
    S=("$WEEKS" --mapping "$MAP")
    [[ $DRY      -eq 1 ]] && S+=(--dry-run)
    [[ $AUTOLOOK -eq 1 ]] && S+=(--auto-lookup)
    [[ -n "$AUTHOR" ]] && S+=(--author "$AUTHOR")
    [[ -n "$OPURL"  ]] && S+=(--url "$OPURL")
    [[ -n "$OPTOK"  ]] && S+=(--token "$OPTOK")
    set +e
    "$SYNC_BIN" "${S[@]}"
    rc2=$?
    set -e
    [[ $rc2 -ne 0 ]] && { echo "  ! phase 2 exited $rc2" >&2; RC=1; }
  else
    echo "==> Phase 2/2 — OpenProject: nothing to sync (no 'op:<wp_id>' tags in $FILE)"
    echo "    Tag a line to track it in OP, e.g.:  DEMO-421 1h Today op:65:Support #data"
  fi
else
  echo "==> Phase 2/2 — skipped (--jira-only)"
fi

exit $RC