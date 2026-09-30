## What & why

<!-- one paragraph: the change and the motivation -->

## Checklist

- [ ] `bash -n` clean on every touched script
- [ ] `./ci/smoke.sh` passes locally (and in the CI run below)
- [ ] `shellcheck -S warning` — new warnings addressed or explained
- [ ] header `--help` updated in the same commit as any behaviour change
- [ ] README table / `entries.example` updated if the entry grammar or flags changed
- [ ] CHANGELOG.md entry added (Fixed/Added/Changed section under the next version)
- [ ] idempotency invariants preserved: op tag never re-logs, never reaches the
      Jira comment, run/add parsers stay in lockstep
- [ ] no secrets, no real `entries` content in the diff or description

## Dry-run evidence

```
paste the relevant --dry-run / --print-map output here (fake keys only)
```
