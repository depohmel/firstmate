# fm-bosun.sh - Scheduled supervisory chores

`bin/fm-bosun.sh` performs firstmate's routine supervisory checks **without
needing a firstmate LLM turn**. It is designed to run every 5–10 minutes from a
scheduler so that mechanical hygiene chores never depend on someone acting on a
warning.

## What it checks and does

Each cycle iterates over every `state/<id>.meta` and runs eight per-task
checks, then two fleet-level ones (deploy drift, idle fleet). Every
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
   While the task is parked with the captain - an armed merge poll against its
   recorded `pr=` or an open captain decision hold covering the task
   (`bin/fm-park-state-lib.sh`) - the re-alarm is suppressed and detection
   resets, so the condition alarms from first sight once the park clears.

5. **Deploy drift** — Shells out to `bin/fm-deploy-drift.sh` (if present) and
   surfaces any output through the same escalation path. The script reads
   `config/deploy-targets.tsv`; a documented example is shipped at
   [docs/examples/deploy-targets.tsv](examples/deploy-targets.tsv).
   A drift line whose project is covered by an open captain decision hold
   (the hold's repo, identity, or title names the project) is suppressed with
   a `deploy-drift:<proj>:suppressed:captain-hold` log; any uncovered line
   still alarms, and an unreadable hold list suppresses nothing.

6. **Stale teardown** — A task whose PR is merged but whose worktree still
   exists is recorded for firstmate; **the bosun never tears down a worktree**.

7. **Stalled run-step** — A no-mistakes step whose status is `running` but
   whose `last_activity` is older than `FM_BOSUN_STALL_SECS` (default 1800),
   or which has an empty `agent_pid`, is escalated. Uses `no-mistakes axi
   status` to read the `active_steps` table.
   Suppressed while the task is parked with the captain (declared `paused:`
   status, armed merge poll against the recorded `pr=`, or open captain
   decision hold - `bin/fm-park-state-lib.sh`); the rate marker is cleared so
   the step alarms at first sight once the park clears.

8. **No-progress crew** — A crew whose worktree has had no file modification
   (excluding `.git`) and no new commit for longer than
   `FM_BOSUN_NPROGRESS_SECS` (default 1800), while the crew is still busy
   (running step or non-terminal status), is escalated.
   Suppressed while the task is parked with the captain (declared `paused:`
   status, armed merge poll against the recorded `pr=`, or open captain
   decision hold - `bin/fm-park-state-lib.sh`); the rate marker is cleared so
   the crew alarms at first sight once the park clears.

9. **Inflight sibling conflicts** — When a task's PR is merged, every other
   open PR in that repo was validated against the old base and may now be
   `CONFLICTING` or behind the base, silently stalling its pipeline. This
   check reads the task's `pr=` URL, lists the repo's open PRs via
   `gh pr list`, and for each sibling calls `gh pr view --json mergeable`
   (surfaces `CONFLICTING`) and `--json behindBase` (surfaces `true`). Siblings
   needing a rebase are escalated as `stale`-kind wakes on the merged task.
   It **reports only** — never rebases, pushes, or writes to any branch.

10. **Idle fleet with queued work** — A fleet-level check that fires when no
    crew has a live endpoint **and** the backlog has ready dispatchable work
    (`tasks-axi ready`, which excludes held and blocked items). When both hold,
    it escalates with the count and top 5 ready ids. This catches the recurring
    pattern where firstmate finishes a wave of work, retires the last worker,
    and stops dispatching while dozens of ready items sit in the backlog.
    Does **not** fire when away mode is active, the backlog has nothing ready,
    everything ready is blocked or held, or the fleet has live crew.

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
| `FM_BOSUN_STALL_SECS` | `1800` | Stalled run-step quiet threshold |
| `FM_BOSUN_NPROGRESS_SECS` | `1800` | No-progress worktree-stale threshold |
| `FM_BOSUN_NM_TIMEOUT` | `10` | Timeout for `no-mistakes axi status` |

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
