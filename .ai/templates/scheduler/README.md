# Scheduling housekeeping

Jig does not implement a scheduler (SPEC §34). These are examples to copy; nothing
here is installed or activated for you.

Both triggers are optional and independent. Either one alone is enough, and running
both is harmless — `jig housekeeping` is idempotent and cheap when nothing is due.

## 1. Session hook (Claude Code)

`.ai/scripts/jig-session-hook` checks the age of `.ai/runtime/last-housekeeping` against
`housekeeping.cadence` and starts housekeeping in the background only when it is due.
When nothing is due the cost is a single `stat`.

Add this to `.claude/settings.json` in your project. Jig never edits that file for you
(ADR-0024) — it is yours, and a merge tool that mangles it would be worse than a line
you paste yourself:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": ".ai/scripts/jig-session-hook" }
        ]
      }
    ]
  }
}
```

If the file already has a `SessionStart` array, add the entry to it rather than
replacing it. `jig status` reports whether the hook is installed.

Codex has no SessionStart equivalent, so Codex users should use a scheduler below.

## 2. External scheduler

Pick the one your machine uses. Replace `/path/to/project` with the project root.

- `cron.txt` — a crontab line.
- `launchd.plist` — macOS, per-user agent.
- `systemd.service` + `systemd.timer` — Linux, per-user units.

Housekeeping exits `3` when a task needs consolidating. That is not a failure: it means
a human or an agent should look, and it is deliberately distinct from `1`, which is a
real error.
