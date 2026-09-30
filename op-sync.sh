#!/usr/bin/env bash
# op-sync.sh — sync Jira worklogs (via twg) to OpenProject time entries.
#
# Usage:
#   OP_BASE_URL=https://op.example.com OP_TOKEN=xxx ./op-sync.sh [WEEKS] [options]
#
# Positional:
#   WEEKS           Sync worklogs from the last N weeks (default: 1)
#
# Options:
#   --url URL       OpenProject base URL (or env OP_BASE_URL)
#   --token TOK     API token, scope: Time & costs (or env OP_TOKEN)
#   --mapping FILE  Jira key -> WP id map, TSV "DEMO-421<TAB>12345<TAB>Activity"
#                   (default: op-mapping.tsv next to this script)
#                   Optional 3rd column sets the OpenProject time-entry
#                   Activity by name (e.g. "Testing", "Design (Solutioning)")
#                   or by numeric activity id. Blank = server default activity.
#   --auto-lookup   If a key is missing from mapping, search OpenProject
#                   work packages whose subject contains the Jira key
#   --author EMAIL  Only sync worklog entries by this author email
#                   (default: sync all authors)
#   --dry-run       Show planned POSTs, write nothing
#   --api-style S   Time-entry payload dialect: 'modern' (duration/workedAt,
#                   OP >=13) or 'legacy' (hours/spentOn, OP <=12).
#                   Default: auto — read /time_entries/schema and pick one.
#                   Override with env OP_TE_STYLE=modern|legacy.
#   -h, --help      Show this help
#
# Debugging: OP_DEBUG=1 logs the target URL and per-entry failures; the API
# token is never echoed.
#
# Idempotency: every created entry carries "sync:jira-worklog-<ID>" plus the
# full Jira issue link (https://<site>/browse/<KEY>) in its comment, and synced
# IDs are appended to STATE_FILE (default ~/.config/op-sync/synced.log) so
# re-runs skip already-synced entries.
#
# Jira link base: taken from the twg payload's request.site, or override with
# env TWG_SITE_URL / JIRA_SITE_URL (e.g. https://jira.example.com).
#
# Jira side is READ-ONLY (twg worklog query). Writes go only to OpenProject.

set -euo pipefail

# twg is located now but required only when the Jira read starts (even --dry-run
# reads Jira worklogs); --help stays dependency-free for CI smoke tests.
if command -v twg >/dev/null 2>&1; then TWG="twg"
elif [[ -x "$HOME/.local/bin/twg" ]]; then TWG="$HOME/.local/bin/twg"
else TWG=""; fi
require_twg() { [[ -n "$TWG" ]] || { echo "twg not found on PATH or ~/.local/bin" >&2; exit 1; }; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# Never echo the token: it is a credential and this script's stdout gets pasted
# into tickets/logs. Set OP_DEBUG=1 for verbose diagnostics on stderr.
op_debug() { { [[ "${OP_DEBUG:-0}" == "1" ]] && printf '  [debug] %s\n' "$*"; } 1>&2 || true; }

WEEKS="${1:-1}"; if [[ $# -gt 0 && "$1" != -* ]]; then shift; fi
case "$WEEKS" in -h|--help) usage; exit 0;; esac
[[ "$WEEKS" =~ ^[0-9]+$ && "$WEEKS" -ge 1 ]] || { echo "WEEKS must be a positive integer" >&2; exit 1; }

URL="${OP_BASE_URL:-}"; TOK="${OP_TOKEN:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MAPPING="$HERE/op-mapping.tsv"
STATE="${OP_SYNC_STATE:-$HOME/.config/op-sync/synced.log}"
AUTO=0; DRY=0; AUTHOR=""; TESTYLE="${OP_TE_STYLE:-auto}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)         URL="$2"; shift 2;;
    --token)       TOK="$2"; shift 2;;
    --mapping)     MAPPING="$2"; shift 2;;
    --auto-lookup) AUTO=1; shift;;
    --author)      AUTHOR="$2"; shift 2;;
    --api-style)   TESTYLE="$2"; shift 2;;
    --dry-run)     DRY=1; shift;;
    -h|--help)     usage; exit 0;;
    *)             echo "unknown option: $1" >&2; exit 1;;
  esac
done
URL="${URL%/}"
[[ -n "$URL" && -n "$TOK" ]] || { echo "need --url/--token or OP_BASE_URL/OP_TOKEN env" >&2; exit 1; }
case "$TESTYLE" in auto|modern|legacy) ;; *) echo "--api-style must be auto|modern|legacy (got '$TESTYLE')" >&2; exit 1;; esac
# Accept either a raw API token or an already-encoded Basic credential
# (base64 of "user:token"). OpenProject ignores the username, so "apikey:" works.
tok_decoded="$(printf '%s' "$TOK" | base64 -d 2>/dev/null || true)"
if ! printf '%s' "$tok_decoded" | grep -qE '^[A-Za-z0-9@._%+-]+:[A-Za-z0-9]+$'; then
  TOK="$(printf 'apikey:%s' "$TOK" | base64 | tr -d '\n')"
  op_debug "raw API token detected -> encoded as Basic base64(apikey:<token>)"
fi
op_debug "url: $URL"
[[ -f "$MAPPING" ]] || { echo "mapping file not found: $MAPPING (create TSV: KEY<TAB>wp_id)" >&2; exit 1; }
require_twg   # every non-help path reads Jira
mkdir -p "$(dirname "$STATE")"; touch "$STATE"
for dep in jq curl; do command -v "$dep" >/dev/null 2>&1 || { echo "missing dep: $dep" >&2; exit 1; }; done

DAYS=$(( WEEKS * 7 ))
CUTOFF_MS=$(( ( $(date +%s) - DAYS * 86400 ) * 1000 ))


# ---- helpers -----------------------------------------------------------------
run_twg() { # echo path of raw JSON result
  local env errf line p raw
  errf="$(mktemp /tmp/ops.err.XXXXXX)"
  env="$("$TWG" "$@" --output json 2>"$errf")" || true
  line="$(printf '%s\n' "$env" | grep -m1 -E '^[[:space:]]*stdout:' || true)"
  [[ -z "$line" ]] && line="$(printf '%s\n' "$env" | grep -m1 -E '^[[:space:]]*compact:' || true)"
  p="$(printf '%s\n' "$line" | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')"
  if [[ -n "$p" && -f "$p" ]]; then rm -f "$errf"; printf '%s\n' "$p"; return 0; fi
  if [[ -n "$env" && "${env:0:1}" == "{" ]]; then
    raw="$(mktemp /tmp/ops.raw.XXXXXX)" || raw=""
    if [[ -n "$raw" ]] && printf '%s\n' "$env" > "$raw"; then rm -f "$errf"; printf '%s\n' "$raw"; return 0; fi
    rm -f "$raw"
  fi
  { echo "--- twg failed: $* ---" >&2; [[ -s "$errf" ]] && head -5 "$errf" >&2; } >&2
  rm -f "$errf"; return 1
}

pt_dur() { # seconds -> ISO8601 duration PT..H..M
  local s=$1 h m out="PT"
  h=$((s/3600)); m=$(( (s%3600)/60 ))
  [[ $h -gt 0 ]] && out="${out}${h}H"
  [[ $m -gt 0 ]] && out="${out}${m}M"
  [[ $h -eq 0 && $m -eq 0 ]] && out="PT${s}S"
  printf '%s' "$out"
}

iso_workedat() { # 2026-09-21T09:00:00.000+0800 -> 2026-09-21T09:00:00+08:00
  printf '%s' "$1" | sed -E 's/\.[0-9]+([+-][0-9]{2})([0-9]{2})$/\1:\2/; s/\.[0-9]+Z$/Z/'
}

# Legacy OpenProject (<=12) books time on a plain date, not a timestamp. The
# Jira "started" value is already the author's local time (incl. their offset),
# so the leading date part is the day the work was logged against.
iso_spenton() { printf '%s' "${1%%T*}"; }

op_get() { curl -s -m 30 -H "Authorization: Basic $TOK" -H "Accept: application/hal+json" "$URL/api/v3$1"; }
op_post() { curl -s -m 30 -w '\n%{http_code}' -X POST "$URL/api/v3$1" \
              -H "Authorization: Basic $TOK" -H "Content-Type: application/hal+json" -d "$2"; }

resolve_wp() { # $1=jira key -> echo wp id or empty
  local id=""
  id="$(awk -F'[ \t]+' -v k="$1" '$1==k{print $2; exit}' "$MAPPING")"
  [[ "$id" == '?' || "$id" == '#'* ]] && id=""   # placeholders = unresolved
  if [[ -z "$id" && $AUTO -eq 1 ]]; then
    local filt
    filt=$(jq -nc --arg k "$1" '[{"subject":{"operator":"~","values":[$k]}}]')
    id="$(op_get "/work_packages?filters=$(jq -rn --argjson f "$filt" '$f|@uri')" \
          | jq -r '._embedded.elements[0].id // empty' 2>/dev/null || true)"
    [[ -n "$id" ]] && echo "  (auto-resolved $1 -> WP $id; add to $MAPPING to persist)" >&2
  fi
  printf '%s' "$id"
}

# ---- activity resolution (mapping column 3 -> OP activity id) -----------------
# OpenProject books each time entry against an Activity (Requirements, Testing,
# Support, ...). The mapping file's optional 3rd column carries either the
# activity name or its numeric id; we translate names via GET /api/v3/activities
# (fetched once and cached). Unresolvable names fall back to the server default.
ACTIVITIES_JSON=""
ACT_CACHE="$(mktemp /tmp/ops.acts.XXXXXX)"
fetch_activities() {
  [[ -n "$ACTIVITIES_JSON" ]] && return 0
  # resolve_activity runs in a $( ) subshell, so a plain variable never caches
  # across keys; persist the list in a temp file instead.
  if [[ -s "$ACT_CACHE" ]]; then ACTIVITIES_JSON="$(cat "$ACT_CACHE")"; return 0; fi
  # Preferred: a collection endpoint. Older OP servers (e.g. the legacy-dialect
  # one this was first run against) 404 on both known collection paths, so we
  # fall back to probing individual activities (GET /time_entries/activities/{id},
  # _type "TimeEntriesActivity") and assemble the list ourselves.
  local ep r id list
  for ep in '/time_entries/activities?pageSize=200' '/activities?pageSize=200'; do
    r="$(op_get "$ep")"
    if printf '%s' "$r" | jq -e '((._embedded.elements // .elements // []) | length > 0)' >/dev/null 2>&1; then
      ACTIVITIES_JSON="$r"
      printf '%s' "$ACTIVITIES_JSON" > "$ACT_CACHE" 2>/dev/null || true
      op_debug "GET $ep -> $(printf '%s' "$ACTIVITIES_JSON" | jq -r '[._embedded.elements[]?|"\(.id):\(.name)"]|join(", ")' 2>/dev/null)"
      return 0
    fi
  done
  list="[]"
  echo "  … resolving OpenProject time-entry activities" >&2
  # Activity ids are sequential from 1; stop at the first 404 instead of a fixed
  # 20-request sweep (each request costs a round-trip and made the run look hung).
  for id in $(seq 1 50); do
    r="$(op_get "/time_entries/activities/$id")"
    [[ "$(printf '%s' "$r" | jq -r '._type // ""' 2>/dev/null)" == "TimeEntriesActivity" ]] || break
    list="$(jq -nc --argjson l "$list" --argjson e "$(jq -c '{id, name}' <<<"$r")" '$l + [$e]')"
  done
  ACTIVITIES_JSON="$(jq -nc --argjson e "$list" '{_embedded:{elements:$e}}')"
  printf '%s' "$ACTIVITIES_JSON" > "$ACT_CACHE" 2>/dev/null || true
  op_debug "probed /time_entries/activities/1..20 -> $(printf '%s' "$ACTIVITIES_JSON" | jq -r '[._embedded.elements[]?|"\(.id):\(.name)"]|join(", ")')"
}

resolve_activity() { # $1=jira key -> echo activity id or empty
  local act id
  # Everything after the first two whitespace-separated fields is the activity
  # value, so multi-word names like "Design (Solutioning)" survive.
  act="$(awk -F'[ \t]+' -v k="$1" '$1==k{ rest=$0; if (sub("^[^ \t]+[ \t]+[^ \t]+[ \t]+", "", rest)) print rest; exit }' "$MAPPING" \
        | sed 's/[[:space:]]*$//')"
  [[ -z "$act" || "$act" == '#'* ]] && return 0
  if [[ "$act" =~ ^[0-9]+$ ]]; then printf '%s' "$act"; return 0; fi
  fetch_activities
  id="$(printf '%s' "$ACTIVITIES_JSON" | jq -r --arg n "$act" '
        ($n | ascii_downcase) as $want
        | ((._embedded.elements // []) + (.elements // []))
        | map(select((.name // "" | ascii_downcase) as $nm
                     | $nm == $want or ($nm | contains($want)) or ($want | contains($nm))))
        | sort_by(if (.name | ascii_downcase) == $want then 0 else 1 end)
        | .[0].id // empty' 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    echo "  ⚠ $1: activity '$act' not found in OpenProject — falling back to the server default activity" >&2
    op_debug "available activities: $(printf '%s' "$ACTIVITIES_JSON" | jq -r '[._embedded.elements[]?.name]|join(", ")' 2>/dev/null)"
    return 0
  fi
  printf '%s' "$id"
}

# ---- preflight: validate token once so we don't fail every POST with 401 -----
ME="$(op_get "/users/me")"
op_debug "GET /users/me -> $(printf '%s' "$ME" | jq -c '{_type, id, login}' 2>/dev/null || printf '%.200s' "$ME")"

ME_LOGIN="$(printf '%s' "$ME" | jq -r '(.login // .name // empty)' 2>/dev/null || true)"
if [[ -z "$ME_LOGIN" ]]; then
  echo "ERROR: OpenProject rejected the token (GET /api/v3/users/me did not return a user)." >&2
  echo "  Token in use: base64 form, length ${#TOK} chars — re-check your OP_TOKEN export for appended/missing characters." >&2
  echo "  Regenerate a personal access token at $URL/my_access_tokens" >&2
  echo "  (scopes: time_entries read/write + work_packages read), then re-export OP_TOKEN." >&2
  exit 1
fi
echo "  authenticated as: $ME_LOGIN" >&2

# ---- API dialect -------------------------------------------------------------
# OpenProject renamed the time-entry fields: 'hours' -> 'duration' and
# 'spentOn' -> 'workedAt' (OP >=13). Posting the wrong pair yields
# HTTP 422 "Multiple field constraints have been violated" because both real
# required fields come back blank. Ask the server which one it speaks.
detect_style() {
  local sch
  sch="$(op_get "/time_entries/schema")"
  printf '%s' "$sch" | jq -r '((.properties // {}) + .)
                              | if has("workedAt") then "modern"
                                elif has("hours") or has("spentOn") then "legacy"
                                else "unknown" end' 2>/dev/null || true
}
if [[ "$TESTYLE" == "auto" ]]; then
  TESTYLE="$(detect_style)"; [[ "$TESTYLE" == "modern" || "$TESTYLE" == "legacy" ]] || TESTYLE="modern"
  op_debug "schema probe -> $TESTYLE"
fi
echo "  time-entry API dialect: $TESTYLE ($([[ "$TESTYLE" == legacy ]] && echo 'hours + spentOn' || echo 'duration + workedAt'))" >&2

te_body() { # $1=style $2=secs $3=started $4=comment $5=wp_id [$6=activity_id] -> time-entry POST payload
  local wp_link="/api/v3/work_packages/$5"
  local act_link=""
  [[ -n "${6:-}" ]] && act_link="/api/v3/time_entries/activities/$6"  # OP's TimeEntriesActivity href (per activity._links in real time entries)
  if [[ "$1" == "modern" ]]; then
    jq -nc --arg dur "$(pt_dur "$2")" --arg at "$(iso_workedat "$3")" \
           --arg cmt "$4" --arg link "$wp_link" --arg act "$act_link" \
       '{duration:$dur, workedAt:$at, comment:{raw:$cmt},
        _links: ({workPackage:{href:$link}}
                 + (if $act != "" then {activity:{href:$act}} else {} end))}'
  else
    jq -nc --arg hours "$(pt_dur "$2")" --arg on "$(iso_spenton "$3")" \
           --arg cmt "$4" --arg link "$wp_link" --arg act "$act_link" \
       '{hours:$hours, spentOn:$on, comment:{raw:$cmt},
        _links: ({workPackage:{href:$link}}
                 + (if $act != "" then {activity:{href:$act}} else {} end))}'
  fi
}

# POST one time entry; sets globals CODE (HTTP status) and JOUT (response body).
op_try_post() {
  local resp; resp="$(op_post "/time_entries" "$1" || true)"
  CODE="${resp##*$'\n'}"; JOUT="${resp%$'\n'*}"
}

# Per-field detail of an APIv3 error body, e.g. "Date can't be blank. [spentOn]"
op_err_detail() {
  printf '%s' "$1" | jq -r '[._embedded.errors[]?
                             | "\(.message // .errorIdentifier) [\(.details.attribute // "?")]"]
                            | join("; ")' 2>/dev/null || true
}

# ---- main loop ---------------------------------------------------------------
SYNCED=0; SKIP=0; FAIL=0; NOMAP=()
SEEN=0; EMPTY=0; READFAIL=0; BADJSON=0; NKEYS=0
KEYS="$(awk -F'[ \t]+' 'NF>=2 && $1 ~ /^[A-Z][A-Z0-9]+-[0-9]+$/ {print $1}' "$MAPPING" | sort -u)"
echo "== OpenProject sync — last ${DAYS} days → $URL (dry-run: $([[ $DRY -eq 1 ]] && echo yes || echo NO)) =="
[[ -n "$KEYS" ]] || echo "  ! no Jira keys in $MAPPING — add rows as 'DEMO-123<TAB><wp_id>' (placeholders '?' are scanned but cannot map)" >&2
for key in $KEYS; do
  NKEYS=$((NKEYS+1))
  echo "  … $key: reading Jira worklogs (last ${DAYS}d)" >&2
  WL="$(run_twg jira workitem worklog query --issue-id "$key" --started-after "$CUTOFF_MS")" \
    || { echo "  !! $key: Jira worklog read FAILED (twg error — check 'twg auth' / network)" >&2; READFAIL=$((READFAIL+1)); continue; }
  ENTRIES="$(mktemp /tmp/ops.ent.XXXXXX)"
  if [[ -n "$AUTHOR" ]]; then
    jq --arg a "$AUTHOR" '{data: [ .data[]? | select((.author.emailAddress // "") == $a) ]}' "$WL" > "$ENTRIES"
  else
    cp "$WL" "$ENTRIES"
  fi
  if ! jq -e 'has("data")' "$ENTRIES" >/dev/null 2>&1; then
    echo "  !! $key: unexpected twg payload (no .data array) — see $ENTRIES" >&2; BADJSON=$((BADJSON+1)); rm -f "$ENTRIES"; continue
  fi
  N=$(jq '.data | length' "$ENTRIES")
  (( N == 0 )) && { EMPTY=$((EMPTY+1)); rm -f "$ENTRIES"; continue; }
  SEEN=$((SEEN+N))
  WP="$(resolve_wp "$key")"
  if [[ -z "$WP" ]]; then echo "  ⏭  $key: $N worklog(s) but no WP mapping — skipped" >&2; NOMAP+=("$key"); rm -f "$ENTRIES"; continue; fi
  [[ "$(awk -F'[ \t]+' -v k="$key" '$1==k{print $2; exit}' "$MAPPING")" == "?"* ]] \
    && echo "     (note: $key is '?' in $MAPPING — pin the real WP id so it stays deterministic)" >&2
  ACT="$(resolve_activity "$key")"
  [[ -n "$ACT" ]] && op_debug "  $key: activity -> id $ACT"
  # Base URL for the Jira issue link embedded in the OP comment: env override
  # first, else the site the twg payload was fetched from, else our default.
  JBASE="${JIRA_SITE_URL:-${TWG_SITE_URL:-}}"
  if [[ -z "$JBASE" ]]; then
    JBASE="$(jq -r '.request.site // empty' "$ENTRIES" 2>/dev/null || true)"
    [[ -n "$JBASE" ]] && JBASE="https://$JBASE"
  fi
  [[ -n "$JBASE" ]] || JBASE="https://jira.example.com"
  JBASE="${JBASE%/}"; [[ "$JBASE" == *"://"* ]] || JBASE="https://$JBASE"
  KSYNC=0; KDUP=0
  for i in $(seq 0 $((N-1))); do
    WID=$(jq -r --argjson i "$i" '.data[$i].id // empty' "$ENTRIES")
    SECS=$(jq -r --argjson i "$i" '.data[$i].timeSpentSeconds // 0' "$ENTRIES")
    ST=$(jq -r --argjson i "$i" '.data[$i].started // .data[$i].created // empty' "$ENTRIES")
    [[ -z "$WID" || -z "$ST" || "$SECS" -eq 0 ]] && { SKIP=$((SKIP+1)); continue; }
    if grep -qxF "$key/$WID" "$STATE" 2>/dev/null; then SKIP=$((SKIP+1)); KDUP=$((KDUP+1)); continue; fi
    CMT="sync:jira-worklog-$WID — $JBASE/browse/$key (op-sync)"
    BODY="$(te_body "$TESTYLE" "$SECS" "$ST" "$CMT" "$WP" "$ACT")"
    if [[ $DRY -eq 1 ]]; then
      echo "  [dry] POST /time_entries <- $BODY"
      continue
    fi
    CODE=""; JOUT=""; ATTEMPT=0
    while :; do
      ATTEMPT=$((ATTEMPT+1))
      op_try_post "$BODY"
      TYPEERR="$(printf '%s' "$JOUT" | jq -r '._type // ""' 2>/dev/null || true)"
      [[ "$CODE" =~ ^20[01]$ && "$TYPEERR" != "Error" ]] && break
      # Self-heal once: if the server rejected the payload because it wants the
      # other dialect's required fields, switch dialect and retry this entry.
      DETAIL="$(op_err_detail "$JOUT")"
      if [[ $ATTEMPT -eq 1 && "$CODE" == "422" ]] && printf '%s' "$DETAIL" | grep -qE '\[(spentOn|hours)\]'; then
        echo "  ↻ $key: server demands spentOn/hours — switching to legacy API dialect and retrying" >&2
        TESTYLE="legacy"; BODY="$(te_body legacy "$SECS" "$ST" "$CMT" "$WP" "$ACT")"; continue
      fi
      break
    done
    if [[ "$CODE" =~ ^20[01]$ && "$TYPEERR" != "Error" ]]; then
      echo "  ✓ $key $(pt_dur "$SECS") @ $ST -> WP $WP${ACT:+ activity $ACT} (op id: $(printf '%s' "$JOUT" | jq -r '.id // "?"' 2>/dev/null))"
      printf '%s/%s\n' "$key" "$WID" >> "$STATE"; SYNCED=$((SYNCED+1)); KSYNC=$((KSYNC+1))
    else
      DETAIL="${DETAIL:-$(printf '%s' "$JOUT" | jq -r '.message // ""' 2>/dev/null)}"
      echo "  ✗ $key worklog $WID failed: HTTP ${CODE:-curl-error} — ${DETAIL:-no error detail returned} (dialect: $TESTYLE, WP: $WP)" >&2
      op_debug "  payload: $BODY"
      FAIL=$((FAIL+1))
    fi
  done
  (( KSYNC == 0 && KDUP > 0 )) && echo "  = $key: $KDUP worklog(s) already synced — nothing new" >&2
  rm -f "$ENTRIES"
done

echo ""
echo "== Result: keys=$NKEYS worklogs_in_window=$SEEN synced=$SYNCED skipped(dup)=$SKIP keys_with_no_worklog=$EMPTY failed=$FAIL (dialect: $TESTYLE) =="
if (( ${#NOMAP[@]} )); then
  echo "  ⚠ unmapped (${#NOMAP[@]}): ${NOMAP[*]}  -> add '<key><TAB><wp_id>' to $MAPPING" >&2
fi
if (( SEEN == 0 )); then
  echo "  ⚠ nothing to sync: no worklogs in the last ${DAYS}d across the ${NKEYS} key(s) scanned." >&2
  echo "    Verify the Jira read directly: twg jira workitem worklog query --issue-id <KEY> --output json" >&2
fi
if (( FAIL || READFAIL || BADJSON )); then
  echo "  ⚠ errors: failed_posts=$FAIL read_failures=$READFAIL bad_payloads=$BADJSON" >&2
  exit 2
fi
exit 0

