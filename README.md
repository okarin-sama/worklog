# worklog — one file, one command: Jira logging + OpenProject sync

A tiny bash toolkit that turns **a single plain-text file** into your whole
timesheet workflow:

```
entries file ──► worklog-run ──► phase 1: logs every NOT-yet-logged line to Jira  (via twg)
                  one command    phase 2: mirrors op:-tagged keys to OpenProject (API v3)
```

Both phases are idempotent — re-run anytime, nothing duplicates.

## Requirements

| Need | Why |
|---|---|
| macOS/Linux with bash 3.2+ | the scripts avoid bash-4+ features on purpose |
| [`jq`](https://jqlang.org), `curl` | JSON + REST calls (`brew install jq`) |
| `twg` (Teamwork Graph CLI) on PATH or `~/.local/bin/twg` | all Jira reads/writes go through it |
| OpenProject personal API token (scope *Time & costs* + read work packages) | phase 2 only |

## Quickstart

```bash
# 1. one-time setup
mkdir -p ~/.config/worklog
cp entries.example ~/.config/worklog/entries
export OP_BASE_URL=https://op.example.com
export OP_TOKEN=<your OP personal token>          # /my_access_tokens
# put the four scripts on PATH (or brew install worklog — see below)

# 2. daily: append lines to your entries file, then
worklog-run --dry-run      # preview both phases (nothing written)
worklog-run --yes          # log to Jira + sync mapped items to OpenProject
```

## The entries file

One entry per line — **the comment is always the LAST part of the line**:

```
KEY DURATION [DATE] op:<wp_id>[:<activity>] COMMENT
```

| Part | Values | Notes |
|---|---|---|
| `KEY` | `DEMO-421` or any Jira link | link keys are resolved from the URL |
| `DURATION` | `3h` `90m` `1h30m` `1h 30m` `0.5d` `2w` | day = 8h, week = 40h |
| `DATE` | `Today` `Yesterday` `YYYY-MM-DD` `ISO ts` | default: today @ `--at` (09:00 +0800) |
| `op:` tag | `op:65` or `op:448:Testing` or `op:448:Design+(Solutioning)` | `+` = space; activity also accepts a numeric id (`op:448:4`); omit the tag for Jira-only lines |
| `COMMENT` | rest of the line, verbatim | `op:`-lookalike words here stay in the comment |

Example lines:

```
DEMO-421 1h Today op:65:Support #data architecture
SAMPLE-10516 2h Yesterday op:448:Testing UAT round 2
INFRA-5413 5m Today
```

### Rules that make re-runs safe

- Every line is fingerprinted (SHA-256 of the whitespace-squeezed line,
  **excluding the op: tag**) into `~/.config/worklog-add/logged.log`. Once a
  line is logged, it is skipped forever — so you keep one growing file and
  never double-log. Adding or editing an `op:` tag later does **not** re-log.
- OpenProject sync dedupes per Jira worklog id in `~/.config/op-sync/synced.log`.
- Only worklogs inside the sync window (`--weeks N`, default 1) are mirrored —
  tag a line and run within the window, or `--weeks 2` to sweep further back.

## Where the entries file lives

Resolution order (first hit wins): `-f FILE` > `$WORKLOG_ENTRIES` >
`./entries` in your current directory > `~/.config/worklog/entries` >
`entries` next to the script (repo checkout layout). This is what makes the
brew-installed binary (which lives in `/opt/homebrew/bin`) usable from anywhere.

## Install via Homebrew

```bash
brew tap okarin-sama/tap
brew install worklog
brew info worklog        # shows setup caveats (twg, OP_TOKEN, WORKLOG_ENTRIES)
```

This installs the commands `worklog-run`, `worklog-add`, `worklog-summary`,
`op-sync` and seeds a sample at `$(brew --prefix)/share/worklog/entries.example`.
The formula lives in the companion [homebrew-tap](https://github.com/okarin-sama/homebrew-tap) repo.

## The four commands

| Command | Role | Handy flags |
|---|---|---|
| `worklog-run` | driver: Jira + OpenProject in one go | `--dry-run` `--yes` `--jira-only` `--op-only` `--weeks N` `--print-map` |
| `worklog-add` | logs entries to Jira only (via twg) | `-f FILE` `--at` `--tz` `--state` `--force` `--notify-false` |
| `op-sync` | mirrors recent Jira worklogs of mapped keys to OpenProject | `WEEKS` `--mapping FILE` `--author EMAIL` `--auto-lookup` `--api-style auto\|modern\|legacy` |
| `worklog-summary` | markdown standup/status report from twg | see `--help` |

Debugging OpenProject sync: `OP_DEBUG=1 worklog-run --op-only` (logs URLs and
per-entry failures; the token is never echoed).

## Repo layout

```
worklog-run.sh      worklog-add.sh      worklog-summary.sh      op-sync.sh
entries.example     README.md           CONTRIBUTING.md         CHANGELOG.md
LICENSE             .gitignore
```

Your real `entries` file and the retired `op-mapping.tsv` are gitignored —
they are personal data, not source.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `twg not found on PATH or ~/.local/bin` | install/authenticate `twg` first (`twg auth`) |
| `need --url/--token or OP_BASE_URL/OP_TOKEN env` | export your OP credentials (phase 2 only — `--jira-only` works without them) |
| `OpenProject rejected the token` | regenerate at `$URL/my_access_tokens` with Time & costs read/write + work packages read |
| line re-logged unexpectedly | you edited the line text itself (duration/comment/date); fingerprints track text, not intent — or use `--force` deliberately |
| `! misplaced op: tag` warning | move the `op:` token to right after the date, BEFORE the comment |
| `activity 'X' not found in OpenProject` | use the exact OP activity name (`+` for spaces) or its numeric id; falls back to server default |

## Contributing & releases

Read [CONTRIBUTING.md](CONTRIBUTING.md) — it covers the script conventions,
the dry-run test checklist, and the tag-and-bump release flow that keeps the
Homebrew tap in sync. Release history lives in [CHANGELOG.md](CHANGELOG.md).