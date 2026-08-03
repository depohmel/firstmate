# fm-bosun.sh - Scheduled supervisory chores

`bin/fm-bosun.sh` performs firstmate's routine supervisory checks **without
needing a firstmate LLM turn**. It is designed to run every 5–10 minutes from a
scheduler so that mechanical hygiene chores never depend on someone acting on a
warning.

## What it checks and does

Each cycle iterates over every `state/<id>.meta` and runs six checks. Every
check can fail (i.e. produce a negative verdict); a predicate that can never say
"no" is not a check.

1. **PR readiness** — For each task with a `pr=` field, compares the PR's newest
   reviewer activity timestamp against the PR head commit timestamp and counts
   outstanding `CHANGES_REQUESTED` reviews. A PR whose review predates its head
   is **not** reviewed. The verdict (`review_ts` vs `head_ts`) is written to the
   task's action log explicitly — never a bare "green". A stale-review steer is
   sent (rate-capped) when needed.

2. **Uncommitted crew work** — For each live task worktree, if there are
   uncommitted changes older than `FM_BOSUN_COMMIT_AGE_SECS` (default 900),
   sends the standard commit steer. The steer is re-sent at most once per
   `FM_BOSUN_STEER_INTERVAL` (default 600) per task.

3. **Unpushed commits** — If the current HEAD is not present on **any** remote
   ref (`git branch -r --contains HEAD`), sends the standard push steer
   (same age threshold and rate-cap as above). This uses the "any remote" check
   rather than `HEAD@{upstream}` because the pipeline commonly pushes without
   setting tracking, in which case `HEAD@{upstream}` silently reports zero
   unpushed commits.

4. **Parked work** — A task whose latest status is `blocked:` or
   `needs-decision:` for longer than `FM_BOSUN_PARKED_AGE_SECS` (default 3600)
   gets escalated by appending a distinct `stale`-kind record to the wake
   queue. Re-escalation backs off exponentially from
   `FM_BOSUN_PARKED_BACKOFF_BASE` (default 600) up to
   `FM_BOSUN_PARKED_BACKOFF_MAX` (default 86400) until the status clears.

5. **Deploy drift** — Shells out to `bin/fm-deploy-drift.sh` (if present) and
   surfaces any output through the same escalation path.

6. **Stale teardown** — A task whose PR is merged but whose worktree still
   exists is recorded for firstmate; **the bosun never tears down a worktree**.

## Hard safety boundaries

- Never merges a PR, never approves or dismisses a review finding, never
  dispatches new work, never tears down a worktree, never force-pushes, never
  touches anything under `projects/` beyond reading.
- Never steers on task **content**. It sends only from a fixed repertoire:
  commit, push, re-read PR comments. Task direction stays firstmate's.
- All actions are logged with a timestamp to `state/.bosun.log` (rotated at
  `FM_BOSUN_LOG_MAX_BYTES`, default 1 MiB).

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `FM_HOME` | repo root | Firstmate home (points at `state/`) |
| `FM_BOSUN_DRY_RUN` | `0` | `1` to log intended actions without sending |
| `FM_BOSUN_COMMIT_AGE_SECS` | `900` | Uncommitted-work age threshold |
| `FM_BOSUN_PUSH_AGE_SECS` | `900` | Unpushed-commits age threshold |
| `FM_BOSUN_PARKED_AGE_SECS` | `3600` | Initial parked-work threshold |
| `FM_BOSUN_PARKED_BACKOFF_BASE` | `600` | Initial re-escalation backoff |
| `FM_BOSUN_PARKED_BACKOFF_MAX` | `86400` | Maximum re-escalation backoff |
| `FM_BOSUN_STEER_INTERVAL` | `600` | Rate-cap for all steers per task |
| `FM_BOSUN_LOG_MAX_BYTES` | `1048576` | Action-log rotation threshold |

## Dry run

```sh
FM_BOSUN_DRY_RUN=1 FM_HOME=/path/to/firstmate/home bin/fm-bosun.sh
```

The log at `state/.bosun.log` shows what it would have done, e.g.:

```
2026-08-03T22:08:18Z  steer:fc-gemma-toolcall-leak:pr-reread:WOULD-send:New reviewer activity on your PR is older than the current head - re-read the PR comments.
2026-08-03T22:08:26Z  stale-teardown:trello-skill-rehome-x2:PR-merged worktree-exists wt=/home/dep/.treehouse/famclaw-skills-cd30de/1/famclaw-skills
```

## Scheduling

The bosun takes a singleton lock (`state/.bosun.lock`) and exits 0 quietly if
another instance holds it, so it is safe to run concurrently with firstmate and
with itself even if a cycle runs long.

### systemd user timer (recommended)

Create `~/.config/systemd/user/fm-bosun.service`:

```ini
[Unit]
Description=Firstmate Bosun: scheduled supervisory chores

[Service]
Type=oneshot
# Adjust these paths to your firstmate checkout and home.
Environment=FM_HOME=%h/tools/firstmate
ExecStart=%h/tools/firstmate/bin/fm-bosun.sh
```

Create `~/.config/systemd/user/fm-bosun.timer`:

```ini
[Unit]
Description=Run Firstmate Bosun every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=fm-bosun.service

[Install]
WantedBy=timers.target
```

Enable and start:

```sh
systemctl --user daemon-reload
systemctl --user enable --now fm-bosun.timer
```

Verify it is firing:

```sh
systemctl --user list-timers fm-bosun.timer
```

### cron alternative

```cron
*/5 * * * * FM_HOME=/home/user/tools/firstmate /home/user/tools/firstmate/bin/fm-bosun.sh
```

### Adjusting the cadence

- **systemd**: change `OnUnitActiveSec=` in the `.timer` file, then
  `systemctl --user daemon-reload && systemctl --user restart fm-bosun.timer`.
- **cron**: change the `*/5` field (e.g. `*/10` for every 10 minutes).