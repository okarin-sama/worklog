# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-10-01

### Added
- **Readable OpenProject comments.** `op-sync` no longer writes a machine id as
  the time-entry comment. Every mirrored entry now spells out the work:

  ```
  DEMO-421 · Data architecture review for the payments service
  - Ticket: Align the reporting pipeline with the new event schema before the Q4 cut …
  - Logged: 2h 10m on 2026-09-30 by Ada Lovelace
  - Worklog: #data rewrote the child ticket descriptions in plain English
  - Jira: https://jira.example.com/browse/DEMO-421
  sync:jira-worklog-73799
  ```

  The ticket summary and description are a best-effort enrich: one batched
  `twg jira workitem get --fields summary,description` per run supplies them for
  every mapped key, and both Atlassian Document Format fields (the description
  and the worklog note) are flattened to prose. If that read fails you get
  `⚠ ticket context unavailable` on stderr and key-only comments — the sync
  itself never stops, and neither dedupe nor tracing change.
- `op-sync --comment-detail full|brief|plain` (env `OP_COMMENT_DETAIL`): `full`
  is the block above, `brief` drops the ticket-description line, `plain` writes
  the previous one-liner and skips the ticket read entirely.
  `op-sync --comment-max N` (env `OP_COMMENT_MAX`, default 220) clips each text
  line with an ellipsis so a wall-of-text ticket cannot swamp the entry.
  `worklog-run` forwards both to phase 2.
- The planned `--dry-run` output now prints the comment the way it will read
  inside OpenProject (the payload escapes its newlines), and the `✓` line shows
  the worklog note instead of an ISO duration — so a run is scannable without
  opening the OP UI.
- `ci/smoke.sh` section 6 drives the whole phase-2 read path offline: a stub
  `twg` answers the worklog query (ADF note) and the ticket-context query, a
  stub `curl` answers the OpenProject REST calls, and the exact planned payload
  is asserted for all three detail modes, the clip length, the degradation path
  and both ticket-response shapes.

### Fixed
- The batched ticket read assumed `.data.items[]` always exists. A one-key
  `workitem get` answers with a **bare `.data[]` array**, which made `jq` abort
  on indexing an array with `items`: any mapping with exactly one key would have
  degraded every comment with no clue why. Both response shapes are now
  normalised, and the shape is pinned by a smoke check.
- `usage()` in `op-sync` printed a hardcoded `sed -n '2,50p'` range, so any new
  option silently fell off the end of `--help`. It now reads the header block up
  to the first non-comment line, like the other scripts.

## [1.2.1] - 2026-09-30

### Fixed
- `worklog-summary` issue links no longer depend on a hardcoded site. Every row now
  links to the URL Jira itself returned for that issue — `url` from the batched
  `workitem get` (newly requested via the `weburl` field), falling back to the graph
  item's `webUrl`, with any `?focusedCommentId=…` suffix stripped so the link points at
  the issue. Previously the report synthesized `https://jira.example.com/browse/<KEY>`
  from a placeholder default, so links were wrong unless you happened to set
  `TWG_SITE_URL`.
- The site base is resolved from the data instead of assumed: observed issue link →
  the hydration payload's `request.site` → the neutral placeholder, and the report
  says which one it used. `TWG_SITE_URL` still wins and is now documented as forcing
  that base for *every* link (for browser-facing hosts the API does not report).

### Added
- Standup bullet **Jira site** and a *Confidence & coverage* bullet describing exactly
  where each row's link came from, plus a ⚠️ warning when no payload carried a site and
  synthesized links therefore fall back to the placeholder.
- `ci/smoke.sh` section 5 drives `worklog-summary` against a stub `twg` and asserts all
  four link paths (payload `url`, graph `webUrl`, `request.site` fallback, placeholder +
  warning) and the `TWG_SITE_URL` override.

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
