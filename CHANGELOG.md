# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-09-30

### Added
- `worklog-summary --order recency|alpha`: evidence-table rows are now ordered by
  latest Jira `updated` (default), with lifetime logged time as the tie-break, and
  the `--max-issues` cut keeps the *most recently touched* issues instead of the
  alphabetically first ones. `--order alpha` restores the previous A-Z behaviour.
- Each report states its own truncation: an `Issue rows:` standup bullet, the same
  note under the evidence table, and a ⚠️ **Row cut** coverage bullet that appears
  only when issues were actually dropped.

### Fixed
- `worklog-summary` silently omitted issues that carry real worklogs but rank low in
  the Teamwork Graph or sort late by key. The key list was cut to `--max-issues`
  *before* hydration, and the per-section cap (`--items`, previously 10) was smaller
  than the number of matched issues — so a low-ranked ticket could never appear,
  however long its window or how much time it held. Hydration is batched and cheap
  (~1s for 40 issues), so all candidates are now fetched, ordered and cut once each
  issue's `updated` timestamp is known.

### Changed
- `worklog-summary --items` default 10 → 100, so candidates survive long enough to be
  ordered. The number of *rows* is still governed by `--max-issues` (default 15): any
  such cut is lossy, and a recency-ordered one keeps different issues than the old
  alphabetical one did. Raise `--max-issues` to the full candidate count for complete
  logged totals — the report now says exactly how many issues were cut.


### Added
- Work-package discovery: `op-sync --list-wps [N]` (default 25) lists OpenProject
  work packages as a `WP_ID  SUBJECT` table so you can pick ids for `op:` tags —
  no `twg`, no mapping file, credentials only. `--wp-filter STR` narrows the
  list to packages whose subject contains STR. `worklog-run --list-wps [N]
  [--wp-filter STR]` forwards the same (works even without an entries file).
- Activity discovery: `op-sync --list-activities` prints the OpenProject
  time-entry activities as an `ID  NAME` table — the exact values usable as the
  `op:<wp_id>:<activity>` suffix or mapping column 3. It reuses the sync's own
  resolution (collection endpoint, per-id probe fallback for older servers), so
  what it lists is what `resolve_activity` can match. Credentials only: no
  `twg`, no mapping file, no Jira read. `worklog-run --list-activities`
  forwards the same (works even without an entries file).

### Fixed
- `op-sync` positional `WEEKS` is now only consumed when it is actually a
  number, so options-only invocations (`op-sync --url … --list-wps`) work.

## [1.0.3] - 2026-09-30

### Changed
- Relicensed from "all rights reserved" to MIT, as the previous `LICENSE` file
  itself prescribed.
- Example Jira project keys and site URLs in docs, comments and the smoke
  battery are now neutral placeholders (`DEMO-421`, `jira.example.com`,
  `op.example.com`) so the repo is safe to publish. The key parser was already
  generic (`^[A-Z][A-Z0-9]+-[0-9]+$`), so this is a documentation-only change.
- Docs describe the public install path: the tap installs from this repo's
  tagged source archive, so no vendored tarball or `gh` token is involved.
- `twg` is Atlassian's public Teamwork Graph CLI; the troubleshooting table now
  links its real installer and `twg login` / `twg setup` / `twg doctor` flow.

## [1.0.2] - 2026-09-30

### Added
- GitHub Actions CI (`macos-latest`): `bash -n` + advisory shellcheck + `ci/smoke.sh`
  behaviour tests; the tap repo has its own `brew style` + install/`brew test` CI.
- `ci/smoke.sh` — dependency-free test battery (help flags, entry grammar,
  positional `op:` extraction, misplaced-tag warning, dry-run plan, sample file).
- PR template + issue forms (bug report / feature request) under `.github/`.

### Changed
- The `twg` requirement is deferred to actual execution: `--help` and (in
  `worklog-add`) `--dry-run` now work on machines without `twg` — required for
  CI and friendlier error UX.

## [1.0.1] - 2026-09-30

### Fixed
- `worklog-run` sibling-tool resolution: phase 1/2 now locate `worklog-add` and
  `op-sync` as `$NAME.sh` (repo layout), extension-less `$NAME` (brew layout),
  or on `PATH` — previously a brew-installed `worklog-run` failed phase 1 with
  exit 127 because it hardcoded the `.sh` filenames.

## [1.0.0] - 2026-09-30

### Added
- `worklog-run.sh` — single-command driver: logs untracked entries to Jira
  (phase 1) and mirrors `op:`-tagged keys to OpenProject (phase 2), building
  the Jira -> WP mapping on the fly. Flags: `--jira-only`, `--op-only`,
  `--dry-run`, `--yes`, `--force`, `--weeks`, `--print-map`, plus forwarding
  of `worklog-add`/`op-sync` options.
- Single maintained file workflow: the old `op-mapping.tsv` is deprecated; the
  Jira -> OpenProject mapping now lives inline per entry as
  `op:<wp_id>[:<activity>]` tags.
- Entries-file resolution order for packaged installs:
  `-f FILE` > `$WORKLOG_ENTRIES` > `./entries` > `~/.config/worklog/entries`
  > `entries` next to the script.
- Homebrew distribution: formula + tap in `homebrew-tap` repo, installed
  commands `worklog-run`, `worklog-add`, `worklog-summary`, `op-sync`.
- Docs: README, CONTRIBUTING (conventions + release process), LICENSE,
  `entries.example`.

### Changed
- Entry grammar: the COMMENT is now always the LAST part of the line —
  `KEY DURATION [DATE] op:<wp_id>[:<activity>] COMMENT`. An `op:` token only
  counts in that fixed position; `op:`-lookalike words inside comments are
  preserved verbatim; a misplaced tag triggers an explicit warning in
  `worklog-run.sh`.
- `worklog-add.sh`: op: tags never reach the Jira comment and never change
  the entry fingerprint, so (re)tagging an already-logged line cannot re-log
  it to Jira.

[1.0.0]: https://github.com/okarin-sama/worklog/releases/tag/v1.0.0
