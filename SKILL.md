---
name: ship
version: 1.2.0
description: |
  Ship the current branch into develop (or another branch) in the background: review,
  fix, push, then open a PR, merge it, and verify the dev deploy, as far as the
  configured stage. `/ship main` (or master) is a prod release: a PR from develop into
  main titled 'prod 🚀' with drafted release notes. Also reports on and stops running
  ships. Use when the user says "/ship", "ship it", "ship this branch", "open a PR for
  this", "ship to prod", "release to main", "ship status", or "stop the ship".
---

# /ship

This skill's `scripts/ship.sh` does the work in its own git worktree, so the developer keeps editing while it runs. This skill plans the ship, starts it, and relays its progress. This skill's `README.md` documents the stages and settings.

It works in any git repo with an `origin` remote. Run every command below from the repo, with the script at `~/.claude/skills/ship/scripts/ship.sh`, written exactly as shown so the permission rules match. A repo the scaffold skill created reviews each push with its own pre-push hook; any other repo is reviewed by this skill's `scripts/code-review.sh`, which `ship.sh` runs before the push. If `ship.sh` reports a `ship_contract` mismatch, relay the error and its fix. Don't work around it.

Decision trailers on the branch's commits (the project's `README.md`, "Decision history") are copied into the PR description, and into the squash commit message when the merge stage squashes, so they survive the merge. `ship.sh` does this; nothing in this skill needs to.

| Invocation | Does |
|---|---|
| `/ship [branch] [stage] [key=value ...]` | Plan, confirm through the permission prompt, start, and report each stage. `branch` is the target, default `develop` |
| `/ship main` (or `master`) | A prod release of `develop` into it; see "Prod release" below |
| `/ship status [id]` | `bash ~/.claude/skills/ship/scripts/ship.sh --status [<id>]`, summarized |
| `/ship stop [id]` | `bash ~/.claude/skills/ship/scripts/ship.sh --stop [<id>]`, and report what it left behind |

Stages, cumulative: `push`, `open_pr` (the default), `merge`, `verify_deploy`. A feature ship targets `develop` unless the invocation names another branch. The only way into `main` or `master` is a prod release.

## Rules

- Start a ship only with the exact `ship.sh --detach ...` command from step 5. Run `ship.sh` only in the forms shown here, and never run `git push`, `gh pr` or `az repos` yourself as part of a ship.
- The permission prompt on `ship.sh --detach` is the only confirmation. Don't ask "shall I proceed?" before it.
- Pass overrides only as `--target`, `--stage`, `--sets` and `--notes-file` arguments, never as environment variables, so they show in the prompt.
- Never edit `.codereviewrc` for a one-run change, and never set `SKIP_CODE_REVIEW`.

## Kickoff

### 1. Build the overrides

- A branch name (any word that isn't a stage or `key=value`) becomes `--target <branch>`. Omit it for `develop`. `main` or `master` makes this a prod release: go to "Prod release" instead of continuing here.
- A stage word becomes `--stage <stage>`.
- Each `key=value` becomes an entry in `--sets`, joined with `;`: `--sets 'review_model=sonnet;pr_reviewers=alice'`.
- Plain language maps to keys: "use sonnet for the review" is `review_model=sonnet`, "have Jane review" is `pr_reviewers=<Jane's GitHub username, or email on ADO>`. If a name doesn't map to a handle you know, ask for it.
- A value containing `'` or `;` can't go through `--sets`. Ask the developer to put it in `.codereviewrc` instead.
- After a denied prompt, a follow-up like "same, but with review_effort=max" keeps the previous overrides and adds the new one.

### 2. Plan

Run `bash ~/.claude/skills/ship/scripts/ship.sh --plan [--target ...] [--stage ...] [--sets '...']`. It's read-only and prints the config block, then `SHIP_ID=`, `SHIP_SHA=`, `SHIP_CONFIG=` and `SHIP_PREFLIGHT=` lines.

### 3. Reviewers (open_pr only)

If the block shows `ship_stage` as `open_pr` and the invocation didn't name reviewers, ask with `AskUserQuestion`, "Add reviewers to this PR?":

- **No reviewers**: add `pr_reviewers=` to `--sets`, so any configured reviewers are cleared for this run.
- **Use configured: <list>**: only when the block's `pr_reviewers` line has a value. Add nothing.
- The automatic "Other" option takes a free-text list. Add `pr_reviewers=<list>` (comma-separated).

If `--sets` changed, run the plan again with it. Skip this step at every other stage and whenever the invocation already set `pr_reviewers`.

### 4. Show the plan

Post the config block from the last plan in a code block.

If `SHIP_PREFLIGHT=failed`, list each `FAIL` line with the fix it names and stop. There's no proceed option. When a fix needs an interactive login, suggest running it in the session with a `!` prefix, for example `! gh auth login`.

### 5. Start

Run exactly, with the same `--target`, `--stage`, `--sets` and `--notes-file` as the last plan:

```
bash ~/.claude/skills/ship/scripts/ship.sh --detach --yes --id <SHIP_ID> --expect-sha <SHIP_SHA> --expect-config <SHIP_CONFIG> [--target ...] [--stage ...] [--sets '...'] [--notes-file ...]
```

- **Prompt denied:** reply "Ship cancelled, nothing was created." and run nothing else.
- **Refused** because HEAD (or `origin/develop`, for a prod release) moved, or a setting or the release notes changed since the plan: say which, and offer to run `/ship` again.
- **Started:** it prints `Ship <id> started in the background`. Go on to step 6.

### 6. Follow it

Start a Monitor on `bash ~/.claude/skills/ship/scripts/ship.sh --watch <id>`. It prints one line per stage transition, `<stage> <state>: <message>`, and exits when the ship finishes. Post each line as a short update. A `waiting` line names what the ship is blocked on (a required check, a review, a deploy approval); say so plainly.

### 7. Report

When the watch exits:

- **Passed:** summarize the PR URL, the merge commit, and the deploy result, as far as the stage went. A `verify_deploy skipped` line means the pipeline's path filters excluded the change, so there was nothing to deploy. That's a pass. Relay the final message's `git branch -d` suggestion (a prod release has none).
- **Failed:** read `.git/ship/<id>/code-review-report.md` for a review failure, otherwise the end of `.git/ship/<id>/ship.log`. Explain what failed and how to fix it. A feature ship keeps its worktree and snapshot branch for inspection; give their paths. After a fix is committed on the developer's branch, `/ship` again ships the new commit.

The ship keeps running if the session closes. `/ship status` picks it up later.

## Prod release

`/ship main` (or `master`) releases `origin/develop`, frozen at its planned commit, into that branch. There's no worktree and no push: every change was reviewed on its way into `develop`. The PR is titled `prod 🚀` and its description is the release notes. It merges with a merge commit and never deletes `develop`. `verify_deploy` checks the dev deploy only, so a prod release stops at `merge` at most.

### 1. Confirm

Ask both with one `AskUserQuestion` call:

- "This is a prod deploy: open a PR merging develop into <branch>?" Options **Yes, prod release** and **No, cancel**.
- "Self-approve and auto-merge into <branch> once its checks pass?" Options **No, a human approves and merges (Recommended)** and **Yes, self-approve and auto-merge**.

If the first answer is no, reply "Ship cancelled, nothing was created." and stop. Otherwise the second sets the stage: no is `--stage open_pr`, yes is `--stage merge` and adds `pr_self_approve=true` to `--sets`. A prod release ignores `ship_stage` from `.codereviewrc`, so always pass `--stage`. On GitHub, approving your own PR isn't allowed, so with yes the merge still waits for any required human review; say so if the plan or the ship reports the self-approval was rejected.

Other `key=value` words from the invocation still go in `--sets`.

### 2. Plan

Run `bash ~/.claude/skills/ship/scripts/ship.sh --plan --target <branch> --stage <stage> [--sets '...']`. If `SHIP_PREFLIGHT=failed`, list each `FAIL` line with its fix and stop. The plan fetches `develop` and `<branch>`, so `SHIP_SHA` is `origin/develop`'s current tip.

With `--stage open_pr`, ask about reviewers as in Kickoff step 3; a prod PR that waits for a human is where they matter most.

### 3. Draft the release notes

Read what's being released, using the `SHIP_SHA` from the plan:

```
git log --no-merges --reverse --format='%h %s%n%b' origin/<branch>..<SHIP_SHA>
bash ~/.claude/skills/ship/scripts/decisions.sh --range origin/<branch>..<SHIP_SHA>
```

Write the notes to `<git-common-dir>/ship/release-notes.md`, where `<git-common-dir>` is what `git rev-parse --git-common-dir` prints (`.git` in a plain checkout), so they stay out of the working tree. Write them for the people who read the prod PR:

- A one-line summary of the release.
- `## Changes`: one bullet per user-visible change, in plain language, grouped under `### Added`, `### Changed` and `### Fixed` where that helps. Merge commits that belong to one change into one bullet. Leave out `Apply code review auto-fix` commits and anything with no visible effect.
- `## Decisions`, only when the decisions output isn't empty: each recorded decision in a sentence.
- Nothing else. Don't invent changes the commits don't show. `ship.sh` adds a footer naming the commit.

Then run the plan again with `--notes-file <that path>` added. The notes are part of `SHIP_CONFIG`, so editing the file afterwards makes the start refuse.

### 4. Show and start

Post the notes, then the config block from the last plan, then run step 5 of Kickoff with `--target`, `--stage`, `--sets` and `--notes-file` exactly as planned. If the developer asks for changes to the notes, edit the file, plan again, and show both again. Follow the ship and report as in Kickoff steps 6 and 7.

## Status

Run `bash ~/.claude/skills/ship/scripts/ship.sh --status` (or `--status <id>`) and summarize each ship: stage, state, what it's waiting on, and its PR. A ship whose process is gone without finishing died unexpectedly; point at its log.

## Stop

Run `bash ~/.claude/skills/ship/scripts/ship.sh --stop` (with `<id>` after it when more than one ship is running; the command says so). Relay what it reports as left behind: an open PR, auto-merge still armed (it merges once checks pass unless cancelled on the PR), the kept worktree and snapshot branch.
