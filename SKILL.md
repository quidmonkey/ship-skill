---
name: ship
description: |
  Ship the current branch into develop in the background: review, fix, push, then
  open a PR, merge it, and verify the dev deploy, as far as the configured stage.
  Also reports on and stops running ships. Use when the user says "/ship",
  "ship it", "ship this branch", "open a PR for this", "ship status", or "stop the ship".
---

# /ship

`scripts/ship.sh` does the work in its own git worktree, so the developer keeps editing while it runs. This skill plans the ship, starts it, and relays its progress. `README.md` ("Shipping") documents the stages and settings.

| Invocation | Does |
|---|---|
| `/ship [stage] [key=value ...]` | Plan, confirm through the permission prompt, start, and report each stage |
| `/ship status [id]` | `make ship-status [ID=<id>]`, summarized |
| `/ship stop [id]` | `make ship-stop [ID=<id>]`, and report what it left behind |

Stages, cumulative: `push`, `open_pr` (the default), `merge`, `verify_deploy`. Ship only ever targets `develop`.

## Rules

- Start a ship only with the exact `make ship ...` command from step 5. Never run `bash scripts/ship.sh`, `git push`, `gh pr`, or `az repos` yourself as part of a ship.
- The permission prompt on `make ship` is the only confirmation. Don't ask "shall I proceed?" before it.
- Pass overrides only as `STAGE=` and `SET=` on the make command, never as environment variables, so they show in the prompt.
- Never edit `.codereviewrc` for a one-run change, and never set `SKIP_CODE_REVIEW`.

## Kickoff

### 1. Build the overrides

- A stage word becomes `STAGE=<stage>`.
- Each `key=value` becomes an entry in `SET`, joined with `;`: `SET='review_model=sonnet;pr_reviewers=alice'`.
- Plain language maps to keys: "use sonnet for the review" is `review_model=sonnet`, "have Jane review" is `pr_reviewers=<Jane's GitHub username, or email on ADO>`. If a name doesn't map to a handle you know, ask for it.
- A value containing `'` or `;` can't go through `SET`. Ask the developer to put it in `.codereviewrc` instead.
- After a denied prompt, a follow-up like "same, but with review_effort=max" keeps the previous overrides and adds the new one.

### 2. Plan

Run `make ship-plan [STAGE=...] [SET='...']`. It's read-only and prints the config block, then `SHIP_ID=`, `SHIP_SHA=`, `SHIP_CONFIG=` and `SHIP_PREFLIGHT=` lines.

### 3. Reviewers (open_pr only)

If the block shows `ship_stage` as `open_pr` and the invocation didn't name reviewers, ask with `AskUserQuestion`, "Add reviewers to this PR?":

- **No reviewers**: add `pr_reviewers=` to `SET`, so any configured reviewers are cleared for this run.
- **Use configured: <list>**: only when the block's `pr_reviewers` line has a value. Add nothing.
- The automatic "Other" option takes a free-text list. Add `pr_reviewers=<list>` (comma-separated).

If `SET` changed, run the plan again with it. Skip this step at every other stage and whenever the invocation already set `pr_reviewers`.

### 4. Show the plan

Post the config block from the last plan in a code block.

If `SHIP_PREFLIGHT=failed`, list each `FAIL` line with the fix it names and stop. There's no proceed option. When a fix needs an interactive login, suggest running it in the session with a `!` prefix, for example `! gh auth login`.

### 5. Start

Run exactly, with the same `STAGE` and `SET` as the last plan:

```
make ship DETACH=1 YES=1 ID=<SHIP_ID> SHA=<SHIP_SHA> CONFIG=<SHIP_CONFIG> [STAGE=...] [SET='...']
```

- **Prompt denied:** reply "Ship cancelled, nothing was created." and run nothing else.
- **Refused** because HEAD moved or a setting changed since the plan: say which, and offer to run `/ship` again.
- **Started:** it prints `Ship <id> started in the background`. Go on to step 6.

### 6. Follow it

Start a Monitor on `make ship-watch ID=<id>`. It prints one line per stage transition, `<stage> <state>: <message>`, and exits when the ship finishes. Post each line as a short update. A `waiting` line names what the ship is blocked on (a required check, a review, a deploy approval); say so plainly.

### 7. Report

When the watch exits:

- **Passed:** summarize the PR URL, the merge commit, and the deploy result, as far as the stage went. A `verify_deploy skipped` line means the pipeline's path filters excluded the change, so there was nothing to deploy. That's a pass. Relay the final message's `git branch -d` suggestion.
- **Failed:** read `.git/ship/<id>/code-review-report.md` for a review failure, otherwise the end of `.git/ship/<id>/ship.log`. Explain what failed and how to fix it. The worktree and snapshot branch are kept for inspection; give their paths. After a fix is committed on the developer's branch, `/ship` again ships the new commit.

The ship keeps running if the session closes. `/ship status` picks it up later.

## Status

Run `make ship-status` (or `make ship-status ID=<id>`) and summarize each ship: stage, state, what it's waiting on, and its PR. A ship whose process is gone without finishing died unexpectedly; point at its log.

## Stop

Run `make ship-stop` (with `ID=<id>` when more than one ship is running; the command says so). Relay what it reports as left behind: an open PR, auto-merge still armed (it merges once checks pass unless cancelled on the PR), the kept worktree and snapshot branch.
