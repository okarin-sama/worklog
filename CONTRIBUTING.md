# Contributing

Thanks for pitching in! This is a small collection of bash scripts with a few
strong conventions. Read this before your first PR — and **star/clone first,
dry-run always**.

## What this project is

A one-command timesheet driver: one maintained `entries` file, phase 1 logs
untracked lines to Jira (via `twg`), phase 2 mirrors `op:`-tagged keys to
OpenProject. Everything must stay **idempotent**: running the same command
twice must never double-log or double-sync. Keep that invariant above all.

## Repo layout

```
worklog-run.sh      driver: phases 1+2, builds the OP mapping from op: tags
worklog-add.sh      phase 1: batch Jira worklogging + fingerprint tracking
op-sync.sh          phase 2: Jira worklog -> OpenProject time entries
worklog-summary.sh  standalone markdown standup/status report
entries.example     the documented entry grammar (copy to ~/.config/worklog/entries)
```

## Script conventions (non-negotiable)

1. **Header comment = `--help`.** Every script prints its own leading comment
   block as usage (`usage()` reads it). If you change behaviour, edit the
   header in the same commit.
2. **Bash 3.2 compatible** (macOS stock): no associative arrays, no
   `${var,,}`, guard empty-array expansion as `${arr[@]+"${arr[@]}"}`.
   Keep `set -euo pipefail`.
3. **Never echo credentials.** Tokens/headers stay out of stdout and debug
   output (`OP_DEBUG=1` is allowed to print URLs and response bodies only).
4. **Dry-run first.** Any new write path must support the existing
   `--dry-run` semantics: show the exact planned mutation, write nothing.
5. **Jira is read-only outside `worklog-add`.** Only phase 1 writes to Jira;
   only phase 2 writes to OpenProject.
6. **State lives in `~/.config/<tool>/`** — never in the repo, never next to
   the scripts (brew installs into `/opt/homebrew/bin`).
7. **Personal data is never committed.** Real `entries` files and mapping
   archives are gitignored on purpose. No tokens, no live issue dumps in
   tests or examples — use `DEMO-421`-shaped fakes.

## The entry grammar

```
KEY DURATION [DATE] op:<wp_id>[:<activity>] COMMENT
```

The COMMENT is the LAST part of the line; the `op:` tag counts only in its
fixed position. If you touch parsing, remember the three invariants:

- the op: tag never reaches the Jira comment;
- the op: tag never changes the entry fingerprint (re-tagging must not re-log);
- `worklog-run.sh`'s tag extractor must accept exactly the same positions as
  `worklog-add.sh`'s parser (they are deliberately mirrored implementations —
  change both or neither).

## Dev loop

```bash
git checkout -b feat/<thing>
# edit, then the standard checklist (all safe: no writes):
bash -n *.sh
./worklog-run.sh --help | head -5
./worklog-run.sh --print-map                    # positional op: tag extraction
./worklog-run.sh --jira-only --dry-run          # phase 1 preview (needs twg auth)
./worklog-run.sh --op-only  --dry-run           # phase 2 preview (needs OP_BASE_URL/OP_TOKEN)
printf 'FAKE-1 1h Today op:448:Design+(Solutioning) note\n' > /tmp/e && \
  ./worklog-add.sh --dry-run -f /tmp/e          # parser edge cases
```

Add a `CHANGELOG.md` entry under "Unreleased" in every PR.

## Style notes

- Small functions with a one-line purpose comment above them; helpers are
  duplicated across scripts (e.g. `run_twg`) to keep each file standalone —
  don't extract a shared library unless all four scripts can source it safely.
- Match the existing output vocabulary: `==> Phase`, `[dry]`, `[skip]`,
  `✓ / ✗ / ⚠ / ↻` markers, `== ... ==` summary lines.
- User-facing errors go to stderr and end with the fix the user should apply.

## Pull requests

- One concern per PR; link the issue if behavioural.
- Include the dry-run output of your checklist in the PR description.
- Update docs in the same PR: header `--help`, README table, entries.example
  if the grammar changed, CONTRIBUTING if a convention changed.

## Releases & the Homebrew tap

The source repo is private and Homebrew will not authenticate private
*formula downloads* — so the release tarball is **vendored into the tap**
(`okarin-sama/homebrew-tap/dist/`). One release = one tag + one tap commit:

```bash
# 1. bump CHANGELOG (Unreleased -> [x.y.z]) and commit
git tag vX.Y.Z && git push origin vX.Y.Z

# 2. build + hash the exact archive of that tag
curl -sL -H "Authorization: Bearer $(gh auth token)" \
  -o ~/repos/homebrew-tap/dist/worklog-X.Y.Z.tar.gz \
  https://github.com/okarin-sama/worklog/archive/refs/tags/vX.Y.Z.tar.gz
shasum -a 256 ~/repos/homebrew-tap/dist/worklog-X.Y.Z.tar.gz

# 3. in the tap repo: update Formula/worklog.rb (url filename, version, sha256)
#    rm the old dist/worklog-*.tar.gz, then
brew style Formula/worklog.rb && git add -A && git commit && git push

# 4. verify from a clean shell:
brew update && brew upgrade worklog && brew test worklog && worklog-run --print-map
```

Version numbers: breaking grammar/behaviour change → major; new flags/phases →
minor; fixes → patch.

## Ideas backlog (good first issues)

- [ ] `worklog-run --watch` (fswatch/loop) that runs on entries-file changes
- [ ] migrate fingerprint state to include the Jira worklog id for exact dedupe
- [ ] `--map KEY=WP:Activity` flag to append tags into the entries file for you
- [ ] shell completion (bash/zsh) for the four commands
- [ ] `entries` linter subcommand (`worklog-run --lint`) with the same
      positional parser shared between run/add

PRs welcome — open an issue first for anything bigger than a flag.
