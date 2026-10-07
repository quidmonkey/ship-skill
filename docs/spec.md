# Spec: /ship skill and background ship pipeline

This is the design of the ship skill as built. `docs/reference.md` is the user-facing guide; this file records how the pieces fit and why.

## Goal

A developer runs `/ship` from a Claude Code session and keeps working. A background job reviews the branch, fixes what the review finds, pushes, and then goes as far as the configured stage: open a PR into `develop`, merge it, and run the project's deploy check. The session reports each stage as it finishes.

All of it runs in a separate git worktree. The review's fix agent never writes to the developer's checkout, and the ship never checks out, pulls or deletes branches there.

## Packaging

The skill lives at `~/.claude/skills/ship` and is its own git repo. Nothing is copied into a project. It works in any git repo with an `origin` remote. The review (`scripts/code-review.sh`), the decision trailer reader (`scripts/decisions.sh`) and the shared helpers (`scripts/lib/common.sh`) all come from the skill. A project's Makefile can include `ship.mk` for the `make ship*` targets; `/ship` doesn't need them.

## Decisions

- Isolation uses a git worktree, not a `/tmp` clone or an MCP server.
- A feature ship targets `develop`, or another branch named in the invocation. `main` and `master` are never feature-ship targets: naming one starts a prod release.
- A prod release follows the same settings as a feature ship. The plan shows the target and every setting, and the developer approving the permission prompt is the human review. Two things are fixed for prod because the alternative breaks the branch model: it merges with a merge commit, and it never deletes `develop`.
- Deploy verification is one command the project supplies (`deploy_check`). The ship doesn't know about pipelines or cloud providers. An earlier version polled ADO and GitHub pipeline runs and checked Cloud Run and Agent Runtime health through `gcloud`. It was dropped: it needed 11 settings, `uv` and `gcloud`, covered only two GCP targets, and had no end-to-end test.
- Each ship has its own log directory, pruned 30 days after it finishes.
- Settings are kept to the choices a developer makes per repo or per run: the stage, reviewers, merge behavior, toolchain, review model and effort, and the deploy check. Values nobody tunes per repo are fixed in the scripts: the second-pass and fix models, one auto-fix retry, the 15-second poll and 30-day log retention. Custom (non-Claude) review and fix agents and a switch to turn the review off were removed.
- Commits, squash messages, PR descriptions and release notes from a ship carry no agent attribution.
- Only `.shiprc` is copied into the worktree. There's no setting for copying other ignored files.
- `.shiprc` is per developer and kept out of git through `.git/info/exclude`. A committed `.gitignore` line was rejected: it meant a plan, which is otherwise read-only, committed on the developer's branch, and it needed rules for when not to (dirty `.gitignore`, detached HEAD, on `develop`).
- A developer never has to configure the toolchain. The first feature ship detects `ship_setup` and `fix_checks` with one read-only agent call and saves them in `.shiprc`. Giving the review agents unrestricted Bash, so they could work out the commands on each ship, was rejected: the worktree isn't a sandbox.
- Writes to the review ledger are locked, and a branch and commit can't be shipped twice at the same time.
- Every `.shiprc` setting can be overridden for one run with `--set key=value` (or `SET=` from make) or a `CR_<KEY>` environment variable.
- Every ship starts with a read-only plan that shows the config. There's exactly one confirmation: the permission prompt on `ship.sh --detach` (or `Proceed? [y/N]` from `make ship` in a terminal). The skill asks no questions of its own. Reviewers are shown in the plan, and a developer who wants others denies the prompt and asks again.

## Stages

Stages are cumulative. Each one includes everything before it.

| Stage | What runs |
|---|---|
| (always) | Preflight, snapshot, worktree, review and fix loop, push |
| `push` | Stops after the push |
| `open_pr` | Opens a PR from the snapshot branch into the target. The default |
| `merge` | Self-approves, arms auto-merge (squash by default, deletes the source branch), and waits for the merge |
| `verify_deploy` | Runs `deploy_check` with the merge commit |

`/ship merge` is shorthand for `--set ship_stage=merge`. If nothing sets it, the stage is `open_pr`.

## Components

| Path | Purpose |
|---|---|
| `SKILL.md` | The `/ship` skill: plan, start, follow, report, status, stop, retry |
| `scripts/ship.sh` | Orchestrates one ship: plan, preflight, worktree, stages. `--plan` prints the config block. Runs in the foreground by default, or `--detach` for the background. `--status`, `--stop` and `--watch` wrap the status helpers. `--retry` resumes a failed or stopped ship |
| `scripts/lib/ship-config.sh` | Loads the helpers, sets `ship_base`, creates `.shiprc` and adds it and the review's report files to `.git/info/exclude` |
| `scripts/lib/common.sh` | Every setting key and its default, `rc_*` to read and write `.shiprc`, the paths a ship never commits, the review ledger, `with_timeout` |
| `scripts/code-review.sh` | The two-pass review and fix loop, run in the worktree before each push |
| `scripts/decisions.sh` | Reads `Decision:` and `Rejected:` commit trailers |
| `scripts/lib/review-docs.sh` | Finds the documents of intended behavior (see Documented intent) |
| `scripts/lib/toolchain.sh` | Detects `ship_setup` and `fix_checks` on a repo's first ship |
| `scripts/lib/ship-status.sh` | Status, event and log helpers, retention pruning, and the status, stop and watch commands |
| `scripts/set-ship-stage.sh` | Writes `ship_stage` into `.shiprc` |
| `ship.mk` | `make ship`, `ship-plan`, `ship-stage`, `ship-status`, `ship-watch` and `ship-stop` |
| `shiprc.template` | What a new `.shiprc` starts as |
| `tests/e2e.sh` | End-to-end checks in throwaway repos, with a stub `claude` and a stub `gh` |
| `~/.claude/settings.json` (user) | `ask` rules for `ship.sh --detach`, `--yes`, `--retry`, `make ship` and `make ship *`; `allow` rules for `--plan`, `--status` and `--watch` |

## Flow

### 1. Plan and confirm

`ship.sh --plan` does steps 1 to 4. It makes no branches or worktrees, prunes nothing, and writes nothing to `.git/ship/`. On a repo's first ship it creates `.shiprc` and adds lines to `.git/info/exclude`, then detects the toolchain into `.shiprc`.

1. Read `.shiprc` and the overrides, and resolve the stage.
2. Refuse if HEAD is detached, if the current branch is the target, `develop`, `main` or `master`, or if the branch has no commits ahead of `origin/<target>`. Warn about uncommitted changes; they aren't part of the ship. Refuse if a running ship already has the same source branch and HEAD SHA.
3. Run preflight for the resolved stage (see Preflight).
4. Generate the ship ID (`<yyyymmdd-hhmmss>-<sha7>`) and print the config block: the snapshot branch and worktree path, the target, the documents the review will check against, the settings the stage uses plus any other override or non-default value, each with its source, the accounts, the preflight results and warnings. The block ends with `SHIP_ID=`, `SHIP_SHA=`, `SHIP_CONFIG=` and `SHIP_PREFLIGHT=passed|failed` lines for the skill to read. `SHIP_CONFIG` is the first 12 characters of `git hash-object` over every resolved `key=value`, the target and the release notes.

Then the developer confirms:

- **`/ship`:** the skill posts the config block verbatim and runs `ship.sh --detach ...` with the planned ID, SHA and config hash. That command hits the user-level `ask` rule, so the permission prompt is the confirmation. Denying it cancels the ship. An `ask` rule outranks any `allow` rule, so the agent can't start a ship without the prompt outside bypass-permissions mode.
- **`make ship` in a terminal:** the script prints the block and asks `Proceed? [y/N]`. Without a terminal it refuses unless `YES=1` is set.
- **Preflight failures:** the block is still shown, with no proceed option. The skill lists the fixes.

### 2. Kickoff

5. Run `ship.sh --id <id> --expect-sha <sha> --expect-config <hash>` with the plan's overrides. If HEAD moved, or any setting, the target or the release notes now resolve differently, refuse and ask for a new `/ship`.
6. Prune expired ship directories (see Retention).
7. Create the snapshot branch `ship/<branch>-<sha7>` at HEAD, or `ship/<target>/<branch>-<sha7>` for a target other than `develop`, so one commit shipped to two targets gets two branches. Seed its review-ledger entry from the source branch's, so commits already reviewed aren't reviewed again.
8. Create the worktree at `../<repo>.ship-<id>` on the snapshot branch, copy `.shiprc` into it, create `working/`, and run `ship_setup`.
9. Create `.git/ship/<id>/`, write `status.json` and the config block at the top of `ship.log`, and point `.git/ship/latest` at it.
10. With `--detach`, start the stages under `nohup`, write `pid`, print the ship ID and exit. Without it, run them in the foreground.

The snapshot freezes the commit being shipped. Later commits on the developer's branch never join this PR, and the developer's own pushes can't collide with fix commits.

### 3. Review, fix, push

1. Run `code-review.sh` in the worktree, then `git push -u origin <snapshot>`, which runs the repo's own hooks.
2. If the review failed and the fix loop left `working/autofix-pending.marker`, commit the fix as `Apply code review auto-fix` and run the review and push again, once. A pre-commit hook that rewrites files fails the first commit; the ship stages its changes and commits once more. A hook that still rejects the commit fails the ship.
3. If REQUIRED findings are still open, copy the report into the ship directory, fail, and keep the worktree for inspection.

### 4. open_pr

Open a PR from the snapshot branch into the target with `gh pr create` or `az repos pr create`, titled with the source branch name. The body lists the commits, the recorded decisions, and the review summary. `pr_reviewers` are added: GitHub users or `org/team`, ADO emails or `[Project]\Team` (added as optional). Record the PR URL, ID and reviewers.

At `merge` and above the PR is approved and auto-completed right away, so named reviewers may never see it. The plan warns when `pr_reviewers` is set at those stages.

### 5. merge

1. If `pr_self_approve` is on, approve (`gh pr review --approve` or `az repos pr set-vote --vote approve`). A rejected self-approval logs a warning and the ship carries on.
2. Arm auto-merge with `pr_merge_method`, deleting the source branch. When the branch has decision trailers and the merge squashes, the squash commit message is set explicitly so they survive.
3. Poll every 15 seconds, up to `pr_poll_timeout`, recording the host's blocking reason as a `waiting` event.
4. Record the merge commit and run `git fetch origin <target>`, which only updates remote refs.

### 6. verify_deploy

Run `deploy_check` with `sh -c` in the worktree (the checkout for a prod release), with `DEPLOY_SHA` set to the merge commit and `DEPLOY_BRANCH` to the target, limited to `deploy_timeout` seconds. Exit 0 passes; anything else, or the timeout, fails the stage. The command owns waiting for the deploy and deciding what a merge that triggered no deploy means.

### 7. Finish

- **Passed:** set `finished_at`, emit the final event, and remove the worktree and local snapshot branch.
- **Failed or stopped:** set `finished_at`, keep the worktree and snapshot branch, and name them in the final event. When the push had passed, or for a prod release, the final event also names the retry command.

### 8. Retry

`ship.sh --retry [<id>]` resumes a ship that failed or was stopped, without a new plan. With no ID it takes the latest ship, and lists the retryable ones if that one isn't.

- **What runs:** the stages from the first one whose events don't record `passed`, through the ship's `ship_stage`. A passed push isn't reviewed or pushed again.
- **Settings:** the values recorded in `status.json`, exported as `CR_<KEY>`, so a retry runs the config the developer approved.
- **Checks:** the ship isn't running and didn't pass; a feature ship's worktree exists and is clean; past the push, origin's snapshot branch is still the local snapshot tip; for a prod release resuming at `open_pr`, `origin/develop` is still the planned commit; the PR host is logged in. It prints a short block and the preflight results, and starts nothing if a check fails.
- **Start:** clears `finished_at`, appends a `retry running` event, and starts in the background. `--watch` starts at the last `retry` event.

A new plan for a commit whose snapshot branch is on origin from a retryable ship fails with "Retry it instead: ship.sh --retry <id>".

## Preflight

Preflight runs every check the resolved stage needs before anything is created or pushed, and reports every failure at once. It prints account names, never tokens.

| Check | Stages |
|---|---|
| On a feature branch with commits ahead of `origin/<target>`; `origin/<target>` exists | all (feature) |
| `origin/develop` has commits the target lacks; no PR from `develop` into the target is open; `ship_stage` isn't `push` | all (prod) |
| `claude`, `git` and the program `ship_setup` starts with are on PATH | all |
| The program each `fix_checks` command starts with is on PATH (a warning: the review runs without that check) | all (feature) |
| Settings are valid: known values, integers where expected, no unknown `CR_*` variables | all |
| `gh auth status`, or `az account show` plus the `azure-devops` extension with org and project defaults | `open_pr` and up |
| Every `pr_reviewers` entry resolves to a user or team | `open_pr` and up, when set |
| `deploy_check` is set and its program is on PATH | `verify_deploy` |

Each failure names its fix, for example "gh isn't logged in. Run `! gh auth login` in the session, then /ship again." If the PR host login expires mid-run, the stage fails with "auth expired at <stage>", anything already armed stays armed, and a retry resumes there once the developer logs in again.

## Status, events and logs

Each ship's files live in `$(git rev-parse --git-common-dir)/ship/<id>/`, which all worktrees share and which is never committed.

| File | Contents |
|---|---|
| `status.json` | Every setting with its source, the current stage and state, PR URL and ID, snapshot and merge SHAs, blocking reason, `started_at`, `finished_at` |
| `events` | One line per stage transition: `<iso-ts>\t<stage>\t<state>\t<message>` |
| `ship.log` | Full output from every step |
| `code-review-report.md` | A copy of the last review report |
| `release-notes.md` | A prod release's approved notes |
| `pid` | The process ID, while it's running |

States are `running`, `waiting` (with a blocking reason), `passed`, `failed` and `stopped`. `status.json` is written one `"key": "value"` per line with the config object last, so the scripts read and update it with `sed` and `awk` and nothing needs `jq`.

`ship.sh --watch [id]` prints each event as `<stage> <state>: <message>`, except the feature kickoff, which prints `kickoff passed` and then each detail on its own `- ` line, because the Monitor truncates long lines. It exits when the ship finishes, or when its process dies without finishing. The finish event is written before `finished_at`, so a watcher that stops at `finished_at` has always seen it.

`ship.sh --stop [id]` collects the ship's descendant processes before sending TERM, since they can't be found once `ship.sh` exits, and signals them too. If `ship.sh` hasn't recorded `stopped` within 15 seconds, the stop command kills it and records the state itself.

With `ship_notify=desktop`, a notification goes out when a ship passes, fails or stops: `osascript` on macOS, a toast through `powershell.exe` on Windows, `notify-send` on Linux.

## Overrides

Precedence, highest first:

1. `--set key=value` (repeatable), `--sets 'k=v;k=v'`, or `SET='k=v;k=v'` from make. `--stage` and `STAGE=` are shorthand for `ship_stage`.
2. The environment variable `CR_<KEY>`. The prefix keeps generic keys like `enabled` and `command` from colliding with unrelated variables.
3. `.shiprc`.
4. The built-in default in `lib/common.sh`.

An unknown key fails the plan and names the closest known key; every `CR_*` variable is checked, so a typo can't be ignored. Values are validated the same way wherever they come from. An empty value means the default. `ship.sh` exports each `--set` value as `CR_<KEY>`, so the review in the worktree sees it. Overrides are never written back.

The skill always passes overrides as `--sets`, never as environment variables, so they show in the permission prompt and the command matches the `ask` rule. Make variables are read only when their `$(origin)` is `command line`, so a stray `YES=1` in the environment can't skip the terminal prompt.

## Retention

At each kickoff, delete ship directories whose `finished_at` is more than 30 days old, with the worktree and snapshot branch each one left. Running ships and whatever `latest` points to are never pruned. A passed or pruned ship's snapshot entry is removed from the review ledger.

## Review base

`code-review.sh` reviews only commits since the branch's last passing review, from the ledger. A branch's first review is based on `origin/<target>`; `ship.sh` passes the target as `REVIEW_BASE_BRANCH`.

## Documented intent

`lib/review-docs.sh` picks the documents that state the repo's intended behavior from the shipped commit, so the plan and the review see the same set:

- `review_docs=auto` (the default) takes whichever of `docs`, `doc`, `ARCHITECTURE.md`, `DESIGN.md` and `README.md` exist.
- `review_docs=<paths>` names them. A named path missing from the commit is left out, and preflight warns.
- `review_docs=none` says there are none.

Every prompt ranks the sources: documents > tests > code, or tests > code with no documents. A `CLAUDE.md` that sets a different order wins. Pass 1 flags tests weakened to make changed code pass. Pass 2 requires a doc update only when a change leaves a documented statement wrong, and with no documents checks only the recorded decisions. The fixer fixes code, not tests, unless a higher source shows the test is wrong. The verifier keeps a finding open when it was "fixed" by changing a test no higher source called wrong.

## Toolchain detection

On a feature ship's plan, for each of `ship_setup` and `fix_checks` that `.shiprc` doesn't set, one `claude -p` call with only `Read`, `Grep` and `Glob` reads the repo's CI config, task runners, manifests and docs, and answers with `SETUP:`, `CHECKS:` and `SOURCE:` lines. The values are appended to `.shiprc` under a comment naming the source and date. Checks that aren't one command (`cd`, `&`, `|`, redirection, `$(`, a `VAR=value` prefix or `#`) are dropped, because each check becomes an allow rule matched from its start. A failed call saves nothing, and the next ship tries again.

The review's agents run headless with `--permission-mode dontAsk` and `--setting-sources user`. Both passes and the verifier may run `git diff`, `git log`, `git show`, `git status` and each `fix_checks` command; the fixer may also edit files.

## Concurrency

Ships of different branches, or different commits on one branch, run side by side, each in its own worktree.

- **Ledger lock.** Every ledger write holds a `mkdir` lock (macOS has no `flock`), retries for 30 seconds, and treats a lock whose PID is dead as stale.
- **No duplicate ships.** The plan refuses a second ship of the same source branch and HEAD SHA while the first runs.
- **Re-shipping a failed commit.** The snapshot branch name is fixed by the commit, so preflight warns that a new ship replaces a failed one's kept worktree and branch, and kickoff removes them. A `ship/*` branch no ship owns fails preflight.
- **Conflicts in the target.** Two ships can each pass review and still conflict once the first merges. The host blocks the second PR, the ship records a `waiting` reason, and it fails at `pr_poll_timeout` with the PR open.

## Prod releases

`/ship main` (or `master`, or `make ship BRANCH=main`) releases `develop` into that branch.

1. **Plan.** Preflight fetches `develop` and the target and freezes `origin/develop`'s tip as `SHIP_SHA`. It skips the feature-branch checks: the current checkout and its uncommitted changes don't matter. It warns if the target has commits `develop` lacks, such as a hotfix.
2. **Release notes.** The skill drafts notes from `git log --no-merges origin/<target>..<SHIP_SHA>` and the recorded decisions into `<git-common-dir>/ship/release-notes.md`, and plans again with `--notes-file`. The notes' hash is part of `SHIP_CONFIG`. Without `--notes-file`, the description is the commit subjects and decisions.
3. **Confirm.** The skill posts the notes and the config block, and the permission prompt is the confirmation.
4. **Run.** No snapshot branch, worktree or push; the stages run from the checkout and touch only the PR host and remote refs. The PR is titled `prod 🚀`. `merge` always uses a merge commit and never deletes `develop`. On GitHub, `gh pr merge --match-head-commit` pins the merge to `SHIP_SHA`, and on both hosts each poll fails the ship if the PR's head moved. `verify_deploy` runs `deploy_check` from the checkout with `DEPLOY_BRANCH` set to the target.

GitHub doesn't let you approve your own PR, so with `pr_self_approve` the merge still waits for any review that branch protection requires.

## Hooks in the worktree

Git sets `GIT_DIR` for hooks in a worktree, which breaks hooks that run git against another repository (`terraform init` with `git::` modules reports `invalid ref`). The ship can't clear it, because git sets it for the hook itself. Pushing from the main checkout was rejected because the hooks would check that checkout's files instead of the snapshot. Shipping from a separate clone was rejected for now: the ship state, the review ledger, hooks, `origin`, repo-local config and `info/exclude` all live in the shared git dir and would each need pointing back. The fix is `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE` in the affected hook. A failed push ends `ship.log` with a `NOTE:` naming `docs/reference.md`, where that's described.

## Out of scope

- Repos with more than one deploy target per branch, unless `deploy_check` handles them.
- An MCP server interface.
- Running ships somewhere other than the developer's machine.
- Copying ignored files other than `.shiprc` into the worktree. A `deploy_check` that needs `.env` has to get its settings some other way.
