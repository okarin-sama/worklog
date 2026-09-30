# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
