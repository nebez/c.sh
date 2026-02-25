# Smoke Tests

Run:

```sh
./tests/smoke.sh
```

What it checks:
- quiet output by default (assistant answer only)
- `-v` and `-vv` verbosity behavior
- auto-resume only for same cwd within the window
- wrapper forces `--sandbox read-only` and `--json`
- random fixture data exists but is never injected into the prompt payload

How non-read/non-leak is validated:
- fixture files are chmod'd unreadable before tests run
- a mock `codex` captures the exact payload passed by `c`
- test asserts sentinel content from fixture files is absent in payload
