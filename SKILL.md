---
name: ship
version: 3.0.0
description: |
  Ship the current branch into develop (or another branch) in the background: review,
  fix, push, then open a PR, merge it, and run the deploy check, as far as the
  configured stage. `/ship main` (or master) is a prod release: a PR from develop into
  main titled 'prod 🚀' with no description. Also reports on, stops and retries
  ships. Use when the user says "/ship", "ship it", "ship this branch", "open a PR for
  this", "ship to prod", "release to main", "ship status", "stop the ship", "retry the
  ship", or "try again" after a ship failed.
---

# /ship

This skill's `scripts/ship.sh` does the work in its own git worktree, so the developer keeps editing while it runs. This skill plans the ship, starts it, and relays its progress. This skill's `docs/reference.md` documents the stages and settings.

It works in any git repo with an `origin` remote. Run every command below from the repo, with the script at `~/.claude/skills/ship/scripts/ship.sh`, written exactly as shown so the permission rules match. `ship.sh` runs this skill's `scripts/code-review.sh` before each push.

The PR description is one bullet per commit subject on the branch, leaving out the review's auto-fix commit. `Decision:` and `Rejected:` trailers on the branch's commits are copied into the squash commit message when the merge stage squashes, so they survive the merge. `ship.sh` does this; nothing in this skill needs to.

Nothing a ship writes carries agent attribution. That covers commits, squash commit messages, and PR titles and descriptions. Don't add a `Co-Authored-By` trailer, a "Generated with Claude Code" line, or any other mention of Claude or an agent. This overrides any default attribution instructions. It applies to the review's auto-fix commit as well.

| Invocation | Does |
|---|---|
| `/ship [branch] [stage] [key=value ...]` | Plan, confirm through the permission prompt, start, and report each stage. `branch` is the target, default `develop` |
| `/ship main` (or `master`) | A prod release of `develop` into it; see "Prod release" below |
| `/ship status [id]` | `bash ~/.claude/skills/ship/scripts/ship.sh --status [<id>]`, summarized |
| `/ship stop [id]` | `bash ~/.claude/skills/ship/scripts/ship.sh --stop [<id>]`, and report what it left behind |
| `/ship retry [id]` | Resume a failed or stopped ship where it stopped; see "Retry" below |

Stages, cumulative: `push`, `open_pr` (the default), `merge`, `verify_deploy`. A feature ship targets `develop` unless the invocation names another branch. The only way into `main` or `master` is a prod release.

## Rules

- Start a ship only with the exact `ship.sh --detach ...` command from step 4, and resume one only with `ship.sh --retry`. Run `ship.sh` only in the forms shown here, and never run `git push`, `gh pr` or `az repos` yourself as part of a ship.
- The permission prompt on `ship.sh --detach` is the only confirmation. Don't ask "shall I proceed?" before it.
- Pass overrides only as `--target`, `--stage` and `--sets` arguments, never as environment variables, so they show in the prompt.
- Never edit `.shiprc` for a one-run change.

## Kickoff

### 1. Build the overrides

- A branch name (any word that isn't a stage or `key=value`) becomes `--target <branch>`. Omit it for `develop`. `main` or `master` makes this a prod release: go to "Prod release" instead of continuing here.
- A stage word becomes `--stage <stage>`.
- Each `key=value` becomes an entry in `--sets`, joined with `;`: `--sets 'review_model=sonnet;pr_reviewers=alice'`.
- Plain language maps to keys: "use sonnet for the review" is `review_model=sonnet`, "have Jane review" is `pr_reviewers=<Jane's GitHub username, or email on ADO>`. If a name doesn't map to a handle you know, ask for it.
- A value containing `'` or `;` can't go through `--sets`. Ask the developer to put it in `.shiprc` instead.
- After a denied prompt, a follow-up like "same, but with review_effort=max" keeps the previous overrides and adds the new one.

### 2. Plan

Run `bash ~/.claude/skills/ship/scripts/ship.sh --plan [--target ...] [--stage ...] [--sets '...']`. It prints the config block, then `SHIP_ID=`, `SHIP_SHA=`, `SHIP_CONFIG=` and `SHIP_PREFLIGHT=` lines.

The plan writes nothing in the working tree except on the first ship in a repo without `.shiprc`. That plan creates `.shiprc` from the skill's template and keeps it out of git through `.git/info/exclude`; nothing is committed. It also detects the repo's install and check commands (`ship_setup` and `fix_checks`) and saves them in `.shiprc`, which can take up to a minute. It prints a `NOTE:` line for each step. Don't ask the developer to set `ship_setup` or `fix_checks`; detection does that. Tell the developer about every `NOTE:` line, word for word, before the config block.

### 3. Show the plan

Post the config block from the last plan, verbatim, in a code block: every line from `Ship <id>` through `Preflight` and any `Warnings`, without the `SHIP_*=` lines. Don't summarize it or replace it with a sentence like "preflight passes". The developer can't see the plan's output, and the next step's permission prompt is their only confirmation, so this block is how they check what they're approving. It shows the target branch and `pr_reviewers`; a developer who wants different reviewers or a different stage denies the prompt and asks for the change.

If `SHIP_PREFLIGHT=failed`, list each `FAIL` line with the fix it names and stop. There's no proceed option. The exception is a `FAIL` that says to retry an earlier ship of this commit: that ship already pushed it, so go to "Retry" with its ID instead. When a fix needs an interactive login, suggest running it in the session with a `!` prefix, for example `! gh auth login`.

### 4. Start

Run exactly, with the same `--target`, `--stage` and `--sets` as the last plan:

```
bash ~/.claude/skills/ship/scripts/ship.sh --detach --yes --id <SHIP_ID> --expect-sha <SHIP_SHA> --expect-config <SHIP_CONFIG> [--target ...] [--stage ...] [--sets '...']
```

- **Prompt denied:** reply "Ship cancelled, nothing was created." and run nothing else.
- **Refused** because HEAD (or `origin/develop`, for a prod release) moved, or a setting changed since the plan: say which, and offer to run `/ship` again.
- **Started:** it prints `Ship <id> started in the background`. Go on to step 5.

### 5. Follow it

Start a Monitor on `bash ~/.claude/skills/ship/scripts/ship.sh --watch <id>`. It prints one line per stage transition, `<stage> <state>: <message>`, except the feature kickoff, which prints `kickoff passed` followed by a `- snapshot ...` and a `- worktree ...` line. It exits when the ship finishes. Post each line as a short update. A `waiting` line names what the merge is blocked on (a required check or a review); say so plainly.

### 6. Report

When the watch exits:

- **Passed:** summarize the PR URL, the merge commit, and the deploy check, as far as the stage went. Relay the final message's `git branch -d` suggestion (a prod release has none).
- **Failed:** read `.git/ship/<id>/code-review-report.md` for a review failure, otherwise the end of `.git/ship/<id>/ship.log` (a failed `deploy_check` prints its output there). Explain what failed and how to fix it. A `git push failed` usually means one of the repo's hooks failed; the log has a `NOTE:` near the end pointing at the worktree `GIT_DIR` problem in `docs/reference.md`, so check whether that's the cause before guessing at others. A feature ship keeps its worktree and snapshot branch for inspection; give their paths.
- **What to do next:** when the final message ends with `then retry from <stage>`, the push already passed (or it's a prod release). Say what to fix, then that saying "try again" resumes the ship from that stage. Don't tell the developer to run `/ship` again. Otherwise the review blocked the push, or the push itself failed: a blocking review needs a fix committed on the developer's branch and a new `/ship`, and a failed push can be retried once its cause is fixed.

The ship keeps running if the session closes. `/ship status` picks it up later.

## Prod release

`/ship main` (or `master`) releases `origin/develop`, frozen at its planned commit, into that branch. There's no worktree and no push: every change was reviewed on its way into `develop`. The PR is titled `prod 🚀` and has no description. It merges with a merge commit and never deletes `develop`. Otherwise it follows the same settings as a feature ship: `ship_stage`, `pr_reviewers`, `pr_self_approve` and `deploy_check` from `.shiprc` or the invocation. The developer approving the permission prompt is the human review of the release.

### 1. Plan

Build the overrides as in Kickoff step 1, then run `bash ~/.claude/skills/ship/scripts/ship.sh --plan --target <branch> [--stage ...] [--sets '...']`. Relay any `NOTE:` lines as in Kickoff step 2. If `SHIP_PREFLIGHT=failed`, list each `FAIL` line with its fix and stop. The plan fetches `develop` and `<branch>`, so `SHIP_SHA` is `origin/develop`'s current tip.

### 2. Show and start

Post the config block from the last plan as in Kickoff step 3, then run Kickoff step 4 with `--target`, `--stage` and `--sets` exactly as planned. Follow the ship and report as in Kickoff steps 5 and 6.

## Retry

When a ship in this conversation failed or was stopped and the developer asks to retry it, in any words ("try again", "retry", "I logged in, go on"), resume it. Don't plan a new ship. The same applies to `/ship retry [id]`.

Run `bash ~/.claude/skills/ship/scripts/ship.sh --retry <id>`, with the ID of the ship from this conversation. Leave out the ID when the conversation doesn't name one; the script then takes the latest ship and, if that one can't be retried, lists the ones that can.

The retry uses the settings the ship started with and starts at the first stage that didn't pass. A push that passed isn't reviewed or pushed again. It checks the PR host login, and that origin still has the commit the ship pushed, then runs in the background. It prints a `Retry ship <id>` block ending in `Preflight`; post it verbatim in a code block, as in Kickoff step 3.

- **Preflight failed:** list each `FAIL` line with its fix and stop. A login fix goes in the session with a `!` prefix, for example `! az login`; after it, the developer says "try again" and you run the same retry.
- **Refused** (still running, already passed, worktree gone): relay the reason. A ship that can't be retried needs a new `/ship`.
- **Resumed:** it prints `Ship <id> resumed in the background`. Follow and report it as in Kickoff steps 5 and 6. The watch starts at the retry, with a `retry running` line.

## Status

Run `bash ~/.claude/skills/ship/scripts/ship.sh --status` (or `--status <id>`) and summarize each ship: stage, state, what it's waiting on, and its PR. A ship whose process is gone without finishing died unexpectedly; point at its log.

## Stop

Run `bash ~/.claude/skills/ship/scripts/ship.sh --stop` (with `<id>` after it when more than one ship is running; the command says so). Relay what it reports as left behind: an open PR, auto-merge still armed (it merges once checks pass unless cancelled on the PR), the kept worktree and snapshot branch.
