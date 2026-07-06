# CodeRabbit review poller (`bin/fm-coderabbit-poll.sh`)

Periodic host-cron poll that watches a captain-maintained queue of GitHub PRs, detects new CodeRabbit reviews, and dispatches a scoped crewmate to address each one.

Designed for CodeRabbit's free-tier org-wide rate limit (1 review per hour): the poll runs hourly and spawns at most one crewmate per newly-posted actionable review.

## Setup

1. Enable the queue:
   ```
   cp docs/examples/coderabbit-queue.txt data/coderabbit-queue.txt
   $EDITOR data/coderabbit-queue.txt
   ```
   Add one `https://github.com/<owner>/<repo>/pull/<n>` URL per line. Blank lines and `#`-comments are ignored.

2. Verify the poll runs cleanly by hand once:
   ```
   bin/fm-coderabbit-poll.sh
   ```
   Silent success means no new reviews (or an empty queue). Look for a `[fm-coderabbit-poll] ... poll cycle complete` line at the end.

3. Install the hourly crontab entry (edit your user crontab with `crontab -e`):
   ```
   0 * * * * /home/<you>/tools/firstmate/bin/fm-coderabbit-poll.sh >> $HOME/.cache/fm-coderabbit-poll.log 2>&1
   ```
   Adjust the path to match your firstmate checkout. The log file makes future debugging trivial.

## What happens on a fire

- Acquires `state/coderabbit-poll.lock` via `flock -n`. Overlapping fires just skip.
- Reads `data/coderabbit-queue.txt`.
- For each PR: queries the newest CodeRabbit review via `gh api /repos/<owner>/<repo>/pulls/<n>/reviews`.
- Compares the review's `submitted_at` timestamp with the per-PR watermark in `state/coderabbit-watermarks.tsv`. If it matches, this review was already processed — skip.
- Parses the review body for the CodeRabbit `Actionable comments posted: N` marker.
   - `N == 0`: advance the watermark, no crewmate. (CodeRabbit posted a "nothing to do" review.)
   - `N > 0`: write the review body to `data/cr-<repo>-pr<n>-<review_id>/review.md`, scaffold a scoped brief, spawn a crewmate via `bin/fm-spawn.sh`. Harness comes from `FM_CODERABBIT_POLL_HARNESS` (default `opencode`); model comes from `FM_CODERABBIT_POLL_MODEL` (default: unset, so `fm-spawn` resolves through `config/crew-dispatch.json` and the harness's own default — no operator-specific tier name is baked into the script). On successful spawn, advance the watermark.
- Releases the lock and exits.

## What the spawned crewmate does

The brief tells it to:
1. Clone the target repo into a scratch subdir of its worktree.
2. Check out the PR branch via `gh pr checkout`.
3. Read the CodeRabbit review body from disk (no re-fetch).
4. For each actionable finding: verify against current code, then either fix with a focused commit OR decline with a brief PR comment.
5. Push its commits and post a summary PR comment enumerating what it fixed vs declined.
6. If any commits were pushed, request a re-review by posting `@coderabbitai review` as a second PR comment. Skipped when the crewmate declined every finding — a re-review with no diff wastes the org-wide quota.
7. Report `done: <summary>` and stop.

Explicit hard rules the crewmate obeys:

- Never merges the PR. Never force-pushes. Never rebases-and-forces.
- Declines destructive, scope-creep, and judgment-heavy findings in a PR comment rather than acting on them.
- Only escalates (`blocked:` / `needs-decision:`) on hard blockers like auth failure or missing tools — NOT on "should I fix this?" style judgment calls.
- Does docs and minor fixes only; production-code rewrites are declined with a comment.

## Files

- `data/coderabbit-queue.txt` — captain-maintained queue, one PR URL per line, gitignored (lives under gitignored `data/`).
- `state/coderabbit-watermarks.tsv` — per-PR last-processed review timestamp, tab-separated. Managed by the poll.
- `state/coderabbit-poll.lock` — the flock file. Empty; safe to `rm` if something is stuck (nothing normally holds it between fires).
- `data/cr-<repo>-pr<n>-<review_id>/` — per-crewmate scoped data (brief + captured review body). Cleaned up on `bin/fm-teardown.sh <id>` after the crewmate finishes.
- `docs/examples/coderabbit-queue.txt` — checked-in example queue file.

## Watermarks and idempotence

The watermark is the review's `submitted_at` ISO timestamp, not its id. If a CodeRabbit re-review posts a NEWER timestamp (which is the normal behavior), the poll dispatches for it. If a fire fails to spawn the crewmate, the watermark is NOT advanced and the next fire retries the same review.

If you want to force a re-dispatch of the newest review on a PR (e.g. after a crewmate wedged and you tore it down), remove the row for that PR from `state/coderabbit-watermarks.tsv`.

## Not-installed environment

- Missing `gh` / `jq` / `flock`: poll fails loudly with a stderr line, exit non-zero. Cron log surfaces the problem.
- Missing queue file (`data/coderabbit-queue.txt` absent): poll exits 0 silently. This is the resting state for a captain who has not opted in.
- No projects under `projects/`: poll logs the error and does not spawn. This can only happen on a nearly-empty firstmate home.

## Interaction with in-flight crewmates

The poll uses the same `bin/fm-spawn.sh` as any other crewmate dispatch. Spawned crewmates appear in `state/*.meta`, in the session-start digest, and are tracked by the watcher exactly like a manually-dispatched task. `bin/fm-teardown.sh` behavior is identical.

The poll does NOT check whether a previous crewmate for the same PR is still running. If a crewmate wedges and cron fires again while the review has advanced, a second crewmate will spawn. In practice this is rare (CodeRabbit's hourly cadence + wedge detection via stale panes catches it first).
