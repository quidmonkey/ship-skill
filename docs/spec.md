# Spec: /ship skill and background ship pipeline

Status: built in scaffold skill version 3.0.0, moved into this standalone skill (ship 1.0.0, scaffold 5.0.0), and made to work in any repo (ship 1.1.0). Ship 1.2.0 finds a repo's documents itself and ranks documents over tests over code in every review prompt (see [Documented intent](#documented-intent)). See [Packaging](#packaging) for the split. See [Implementation notes](#implementation-notes) for what the build added or settled. Deploy verification has been tested against stubbed `gh`, `gcloud` and `curl` only.

## Packaging

The ship skill lives at `~/.claude/skills/ship` and is its own git repo (`git@github.com:quidmonkey/ship-skill.git`). Nothing from it is copied into a project. A project gets it in two ways: the scaffold skill clones it if it's missing (and checks its minimum version), and the project's `make setup` clones it if it's missing.

The review tooling comes from one of two places, and `lib/ship-config.sh` picks it when it's sourced:

- **Project.** A scaffolded repo keeps the review half of the pipeline, written by the scaffold skill: `scripts/code-review.sh` (the pre-push hook), `scripts/decisions.sh` and `scripts/lib/common.sh`. `common.sh` is the contract between the two repos. The ship skill sources it from the project root and uses `rc_*`, `ledger_*`, `with_timeout` and `autofix_marker`. It carries `ship_contract=1`, and `lib/ship-config.sh` refuses to run against any other value. The pre-push hook is the review.
- **Skill.** Any other repo, including one whose `scripts/lib/common.sh` has no `ship_contract` line. The skill sources its own `scripts/lib/common.sh` and runs its own `scripts/code-review.sh` in the worktree before each push. Both are copies of the scaffold skill's templates. The review copy adds `fix_checks`, the lint and test commands its reviewers and fixer may run, in place of the template's fixed `uv run pytest`, `uv run pre-commit` and `make run-check`. It also finds the repo's documents instead of assuming the scaffold's `docs/` layout (see Documented intent).

`scripts/decisions.sh` comes from the project when it has one and from the skill otherwise. The ship keys, their defaults (through the `rc_default_extra` hook in `rc_default`) and `ship_base` live in `lib/ship-config.sh`.

A project's Makefile can include the skill's `ship.mk` for the `ship*` targets; a scaffolded one does, and falls back to targets that say to run `make setup` when the skill is missing. `/ship` doesn't need them: it calls `scripts/ship.sh` directly. The ship settings live in `.shiprc`, which the first ship in a repo creates from the skill's `shiprc.template` (see Configuration).

## Goal

A developer runs `/ship` from a Claude Code session and keeps working. A background job reviews the branch, fixes what the review finds, pushes, and then goes as far as the developer's configured stage: open a PR into `develop`, merge it, and verify the dev deploy. The session reports each stage as it finishes.

Today the same work blocks the developer in three ways:

1. The pre-push review runs in the foreground (up to 4 review passes and 2 fix passes at `agent_timeout=900` each), then `ship.sh` polls for the merge for up to `pr_poll_timeout=1800`.
2. The fix agent writes into the developer's working tree, so they can't keep editing, and `ship.sh` has to ask before committing the fix.
3. `ship.sh` finishes with `git checkout <base>`, `git pull` and `git branch -d` in the developer's checkout.

The new design moves all of it into a separate git worktree, so none of it touches the developer's checkout.

## Decisions already made

- Isolation uses a git worktree, not a `/tmp` clone or an MCP server.
- A feature ship opens PRs into and merges into `develop`, or another branch named in the invocation. `main` and `master` are never feature-ship targets: naming one starts a prod release (see [Prod releases](#prod-releases)).
- Deploy verification covers the dev environment only. A prod release stops at `merge` at most.
- Each repo has one deploy target: one Cloud Run service or one Agent Runtime (formerly Agent Engine).
- Self-approval is allowed on the target repos.
- If a merge doesn't trigger a deploy run (because of pipeline path filters), there's nothing to verify, and the stage is recorded as skipped.
- Deploy tagging with the commit SHA is optional. It becomes a scaffold question, and verification falls back to timing checks when tags aren't there.
- Each ship has its own log directory. Directories are pruned 30 days after the ship finishes.
- Scaffolded projects use `develop` as the default branch.
- Commits, squash messages, PR descriptions and release notes from a ship carry no agent attribution: no `Co-Authored-By` trailer and no "Generated with" line.
- Only `.shiprc` and `.codereviewrc` are copied into the worktree. There's no setting for copying other gitignored files.
- The ship's settings are in `.shiprc`, ignored through a committed `.gitignore` line. The first ship in a repo creates both and says so in the session.
- A developer never has to configure the toolchain. The first feature ship detects `ship_setup` and `fix_checks` with one read-only agent call and saves them in `.shiprc`; it isn't repeated on every ship, so plans stay fast and the plan and kickoff hash the same settings. Giving the review agents unrestricted Bash, so they could work out the commands on each ship, was rejected: the worktree isn't a sandbox.
- Repos the scaffold didn't create get the ship pipeline through a documented manual install.
- Writes to the review ledger are locked, and a branch and commit can't be shipped twice at the same time.
- Every `.shiprc` setting can be overridden for one run with `--set key=value` (or `SET=` from make) or a `CR_<KEY>` environment variable.
- Every ship starts with a read-only plan that shows the config. There's exactly one confirmation: the permission prompt on `ship.sh --detach` (or `make ship` from a terminal). Nothing runs until the developer approves it, and denying it leaves everything as it was. The one exception to a single prompt is `open_pr` without named reviewers: the skill asks for reviewers before the plan.

## Stages

Stages are cumulative. Each one includes everything before it.

| Stage | What runs |
|---|---|
| (always) | Preflight checks, snapshot, worktree, review and fix loop, push |
| `push` | Stops after the push |
| `open_pr` | Opens a PR from the snapshot branch into `develop`. **Default.** |
| `merge` | Self-approves, arms auto-complete (squash, delete source branch), and waits for the merge |
| `verify_deploy` | Waits for the dev pipeline run on the merge commit, checks the service is healthy, runs the smoke test |

The stage is resolved like any other setting (see Overrides): `/ship merge` is shorthand for `--set ship_stage=merge`. If nothing sets it, the stage is `open_pr`.

## Components

| Path | Purpose |
|---|---|
| `SKILL.md` (this skill) | The `/ship` skill: kickoff, status, stop, and stage notifications |
| `scripts/ship.sh` (this skill) | Orchestrates one ship: plan, preflight, worktree, stages. `--plan` prints the config block and creates nothing. Runs in the foreground by default, or `--detach` for the background. `--status`, `--stop` and `--watch` wrap the status helpers |
| `scripts/lib/ship-config.sh` (this skill) | Picks the project's tooling or the skill's (see Packaging), checks `ship_contract`, adds the ship keys and their defaults, sets `ship_base`, creates `.shiprc` and commits it to `.gitignore` (see Configuration), reads each key from `.shiprc` or, for a project's review keys, its `.codereviewrc`, and adds the review's report files under `working/` to `.git/info/exclude` when nothing ignores them |
| `scripts/code-review.sh`, `scripts/decisions.sh`, `scripts/lib/common.sh` (this skill) | The review tooling for repos without their own |
| `scripts/lib/review-docs.sh` (this skill) | Finds the documents of intended behavior for the skill's review and the plan's `docs` line (see Documented intent) |
| `scripts/lib/toolchain.sh` (this skill) | Detects `ship_setup` and `fix_checks` on a repo's first ship and saves them in `.shiprc` (see Configuration) |
| `tests/e2e.sh` (this skill) | End-to-end checks up to the push stage in throwaway repos, with stubbed review and fix agents |
| `scripts/lib/ship-status.sh` (this skill) | Status, event and log helpers, retention pruning, and the status, stop and watch commands |
| `scripts/lib/ship-deploy.sh` (this skill) | Deploy verification: find the run, health check, smoke test |
| `scripts/set-ship-stage.sh` (this skill) | Writes `ship_stage` into the project's `.shiprc` |
| `ship.mk` (this skill) | `make ship [STAGE=..] [SET=..] [DETACH=1] [YES=1]`, `make ship-plan [STAGE=..] [SET=..]`, `make ship-stage STAGE=..`, `make ship-status [ID=..]`, `make ship-watch [ID=..]`, `make ship-stop [ID=..]`; `make auto-pr` is an alias for `make ship-stage STAGE=merge` |
| `shiprc.template` (this skill) | What a new `.shiprc` starts as (see Configuration) |
| `scripts/lib/common.sh` (project, optional) | `rc_get` checks the `CR_<KEY>` environment variable before the rc file (see Overrides); the review keys, read from the project's `.codereviewrc`; the ledger; `ship_contract` |
| `scripts/code-review.sh` (project, optional) | The pre-push review. Honors `REVIEW_BASE_BRANCH` for a branch's first review (see Review base) |
| `Makefile` (project, optional) | Includes `ship.mk`; `make setup` clones this skill if it's missing |
| `~/.claude/settings.json` (user) | `ask` rules for `ship.sh --detach`, `ship.sh --yes`, `make ship` and `make ship *`; `allow` rules for `ship.sh --plan`, `--status` and `--watch`. A scaffolded project's `.claude/settings.json` carries the `make ship` rules too |

## Flow

### 1. Plan and confirm (read-only, a few seconds)

`ship.sh --plan` does steps 1 to 4. It doesn't prune logs, make branches or worktrees, or write to `.git/ship/`. The one thing it may create is `.shiprc` and its `.gitignore` commit, on a repo's first ship (see Configuration), before it reads HEAD. On that ship it also detects the toolchain into `.shiprc`.

1. Read and validate `.shiprc`, and resolve the stage.
2. Refuse to continue if HEAD is detached, if the current branch is `develop` or `main`, or if the branch has no commits ahead of `origin/develop`. Warn, but don't block, if there are uncommitted changes. They aren't part of the ship. Also refuse if a running ship already has the same source branch and HEAD SHA. A running ship is one with a live `pid` and no `finished_at`.
3. Run preflight for the resolved stage (see Preflight).
4. Generate the ship ID (`<yyyymmdd-hhmmss>-<sha7>`) and print the config block (see Status, events and logs). The block shows the exact snapshot branch and worktree path this ship will use. With the skill's tooling it also shows the documents the review will check against, or why there are none. It also lists preflight results and warnings.

**Reviewer question (skill only).** Before running the plan, `/ship` works out the stage using the normal precedence. If the stage is `open_pr` and the invocation didn't set `pr_reviewers`, the skill asks "Add reviewers to this PR?". The options are:

- **No reviewers**
- **Use configured: <list>**, shown only when `.shiprc` or `CR_PR_REVIEWERS` has a value
- **Other**, a free-text list of emails or teams

The answer becomes `--sets 'pr_reviewers=...'` for the plan, so preflight checks the names and the config block shows them. The question is skipped at every other stage, and whenever the invocation already names reviewers (`/ship pr_reviewers=...` or "ship it and have Jane review"). `make ship` in a terminal never asks: it uses the configured value or `SET`.

This question collects input. It doesn't replace the confirmation, which is still the single permission prompt below.

Then the developer confirms:

- **`/ship`:** the skill posts the config block, then runs step 5 with the planned ID and SHA. That command, `ship.sh --detach ...`, hits the user-level `ask` permission rule, so the Claude Code permission prompt is the only confirmation. The skill doesn't ask a question of its own. Approving starts the ship. Denying cancels it: the skill replies "Ship cancelled, nothing was created" and runs nothing else. The agent can't start a ship without that prompt, even outside the skill, because an `ask` rule outranks any `allow` rule. The one exception is a session running in bypass-permissions mode, which skips every prompt.
- **`make ship` in a terminal:** the script prints the block and asks `Proceed? [y/N]`. Anything but `y` exits 0 with nothing created. Without a terminal, `make ship` refuses to run unless `YES=1` is set.
- **Preflight failures:** the block is still shown, but there's no proceed option. The skill lists the fixes instead.

### 2. Kickoff (in the developer's checkout, a few seconds)

5. Run `ship.sh --id <id> --expect-sha <sha> --expect-config <hash>` with the same overrides the plan had. The plan prints `<hash>`, a hash of every resolved setting. If HEAD has moved since the plan, any setting now resolves differently, or a check that passed in the plan now fails, refuse, and tell the developer to run `/ship` again. That way the developer never approves one config and gets another.
6. Prune expired ship directories (see Retention).
7. Create the snapshot branch `ship/<branch>-<sha7>` at HEAD, or `ship/<target>/<branch>-<sha7>` for a target other than `develop`, so one commit shipped to two targets gets two branches. Seed its ledger entry in `.git/code-review-ledger` from the source branch's entry, so commits already reviewed aren't reviewed again. The write takes the ledger lock (see Concurrency).
8. Create the worktree at `../<repo>.ship-<id>` on the snapshot branch. Copy `.shiprc` and any `.codereviewrc` into it, since both are ignored. Create `working/`. Run `ship_setup` (`uv sync -q` by default when the repo has a `pyproject.toml`). Before the worktree is created, the review's files (`working/code-review-report.md`, `code-review-findings.md`, `code-review-fix-summary.md` and `autofix-pending.marker`) and `.shiprc` (plus `.codereviewrc` with the project's tooling) go into `.git/info/exclude` unless they're already ignored, listed or tracked. The list names files rather than `working/`, so a repo that tracks its own `working/` still commits fixes there. The auto-fix commit's `git add -A` skips them when they're ignored, and leaves out by pathspec any that aren't, such as a tracked `.shiprc`.
9. Create `.git/ship/<id>/`. Write the config block to `status.json` and to the top of `ship.log`. Point `.git/ship/latest` at the new directory.
10. With `--detach`: re-launch the rest under `nohup`, write `pid`, print the ship ID, and exit 0. Without it, continue in the foreground and stream `ship.log`.

The snapshot freezes the commit being shipped. Later commits on the developer's branch never join this PR, and the developer's own pushes to their branch can't collide with fix commits.

### 3. Review, fix, push (in the worktree)

1. Review, then push. With the skill's tooling, run its `code-review.sh` in the worktree, then `git push -u origin <snapshot>`, which runs the repo's own hooks. With the project's tooling, `git push` alone: the pre-push hook runs the two-pass review.
2. If the push is blocked and the fix loop left `working/autofix-pending.marker`, commit the fix automatically with the existing message and push again, up to `ship_fix_retries` times. The commit runs the repo's pre-commit hook. A hook that rewrites files, such as a formatter, fails the first try; the ship stages what it changed and commits once more, and the re-push reviews it with the fix. A hook that still rejects the commit fails the ship with a message naming the hook. There's no confirmation prompt: the working tree belongs to the ship, and the re-push runs the full review again.
3. If the push is blocked with REQUIRED findings still open, copy `working/code-review-report.md` into the ship directory, set the state to `failed`, and keep the worktree for inspection.

### 4. open_pr

1. Open a PR from the snapshot branch into `develop` using `gh pr create` or `az repos pr create`. The host is detected from `origin`, as today. The title is the source branch name. The body lists the commits and links the review report summary.
2. If `pr_reviewers` is set, add each reviewer to the PR.
   - GitHub: `gh pr create --reviewer <list>`. Each entry is a username or an `org/team`.
   - ADO: `az repos pr create --reviewers <list>`. Each entry is an email or UPN, or a team as `[Project]\Team`.

   ADO reviewers are added as optional. Whether to mark them required (`az repos pr reviewer add`, or the REST API's `isRequired` flag) is left to implementation, once there's a real case for it.
3. Record the PR URL and ID, plus the reviewers that were added.

At the `merge` stage and above, the PR is approved and auto-completed right away, so named reviewers may never get to review before it merges. If `pr_reviewers` is set with one of those stages, the plan shows a warning that suggests `open_pr` instead. The ship still runs if you approve.

### 5. merge

1. Approve (`gh pr review --approve` or `az repos pr set-vote --vote approve`). If approval fails, log a warning and keep going.
2. Arm auto-merge or auto-complete: squash, and delete the source branch. When the branch has decision trailers, the squash commit message is set explicitly so they survive ([decision-trailers.md](decision-trailers.md)).
3. Poll every `pr_poll_interval` seconds, up to `pr_poll_timeout`. While waiting, record the blocking reason from the host (failing policy, required check) in `status.json` so `/ship status` shows it.
4. When the PR merges, record the merge commit. On ADO that's `lastMergeCommit.commitId`, and on GitHub `mergeCommit.oid`.
5. Run `git fetch origin develop`. This only updates remote refs. The developer's checkout, current branch and local branches are never touched. The final message suggests `git branch -d <branch>` if the developer is done with it.

### 6. verify_deploy

Everything below uses the merge commit.

1. **Find the run.** Poll for a run of `deploy_pipeline` on `develop` whose source commit is the merge commit, for up to `deploy_run_grace` (default 300s).
   - ADO: `az pipelines runs list --pipeline-ids <id> --branch develop`, filtered on `sourceVersion`.
   - GitHub: `gh run list --workflow <name> --commit <sha>`.

   If no run appears, the pipeline's path filters excluded this change. Set the stage to `skipped` with the message "no deploy triggered" and end the ship as passed.

2. **Wait for the run.** Poll until it completes, up to `deploy_poll_timeout`. Any result other than succeeded fails the stage, and the run URL goes into the status. If a stage is waiting on an approval gate, record that as the blocking reason.

3. **Check health** (`gcloud`, read-only).

   | Provider | Healthy means | `deploy_match=sha` | `deploy_match=time` |
   |---|---|---|---|
   | `cloud_run` | `gcloud run services describe` shows Ready=True and 100% of traffic on the latest ready revision | That revision is named `<service>-<sha12>` or has a `commit` label equal to `<sha12>` | That revision's creation time is after the run started |
   | `agent_runtime` (or `agent_engine`, its earlier name) | The reasoning engine with display name `deploy_name` exists in `deploy_project`/`deploy_region` | The engine's `commit` label equals `<sha12>` | The engine's `updateTime` is after the run started |

   The Agent Runtime checks call the Vertex AI REST API with a token fetched inside the script. The token is never printed or logged. Which API fields to use (engine versus runtime revision) gets confirmed during implementation against Brady.Adk.SalesAgent.

   When `deploy_match` is unset, it defaults to `time`. The scaffold sets it to `sha` for projects that tag deploys.

4. **Smoke test.** Run `deploy_smoke` in the worktree, with a limit of `deploy_smoke_timeout` (default 900s). It gets these environment variables:
   - `DEPLOY_URL`: the Cloud Run URL. It's a local proxy URL when `deploy_proxy=true`.
   - `DEPLOY_RESOURCE`: the Agent Runtime resource name.
   - `DEPLOY_SHA`: the merge commit.

   When `deploy_proxy=true`, the script starts `gcloud run services proxy` on a free local port first and stops it afterward. That's for private services, where the smoke test can't mint an ID token from user credentials.

   The smoke command's exit code decides the result. A smoke test that fails open (skips and exits 0 when it can't reach the target) would make this check meaningless. The config comment and the docs tell users to set that test's require-live flag, for example `SMOKE_TEST_REQUIRE_LIVE=1`.

### 7. Finish

- **Passed:** set `finished_at`, emit a final event, remove the worktree, and delete the local snapshot branch.
- **Failed or stopped:** set `finished_at`, keep the worktree and snapshot branch for inspection, and put their paths in the final event.

## Preflight

Preflight runs every check the resolved stage needs, before anything is created or pushed. It reports every failure at once, not just the first. It prints account names but never tokens.

| Check | Stages |
|---|---|
| On a feature branch with commits ahead of `origin/develop`; `origin/develop` exists | all |
| `claude` and `git` are on PATH, and the program `ship_setup` starts with; with the project's tooling, the pre-push hook is installed | all |
| The program each `fix_checks` command starts with is on PATH (a warning, not a failure: the review runs without that check) | all, skill's tooling |
| `uv` is on PATH | `verify_deploy` |
| `.shiprc` values are valid: the stage is a known value, numbers are integers | all |
| `gh auth status`, or `az account show` plus the `azure-devops` extension with org and project defaults set | `open_pr` and up |
| Every `pr_reviewers` entry resolves to a real user or team (`gh api users/<name>` or `gh api orgs/<org>/teams/<team>`; `az devops user show --user <email>` or a team lookup) | `open_pr` and up, when set |
| `deploy_pipeline` resolves (`az pipelines show` / `gh workflow view`) | `verify_deploy` |
| `deploy_provider`, `deploy_project`, `deploy_region`, `deploy_name` and `deploy_smoke` are set | `verify_deploy` |
| `gcloud` has an active account and can read the target: `gcloud run services describe`, or a GET on the reasoning engine | `verify_deploy` |

Each failure message names its fix. For example: "gh isn't logged in. Run `! gh auth login` in the session, then `/ship` again."

Background runs can't log in interactively. If credentials expire mid-run, the stage fails with "auth expired at <stage>". Anything already armed stays as it is: an open PR stays open, and auto-complete stays set.

## Status, events and logs

Each ship's files live in `$(git rev-parse --git-common-dir)/ship/<id>/`, which all worktrees share and which is never committed.

| File | Contents |
|---|---|
| `status.json` | The config block, the current stage and state, PR URL and ID, snapshot and merge SHAs, deploy run URL, blocking reason, `started_at`, `finished_at` |
| `events` | One line per stage transition: `<iso-ts>\t<stage>\t<state>\t<message>`. The skill watches this file |
| `ship.log` | Full output from every step. Fix retries append to it |
| `code-review-report.md` | A copy of the last review report |
| `pid` | The background process ID, while it's running |

`.git/ship/latest` is a symlink to the newest ship directory.

States are `running`, `waiting` (with a blocking reason), `passed`, `skipped`, `failed` and `stopped`.

The config block records:

- the ship ID, source branch, and snapshot branch and SHA
- the worktree path and target branch (`develop`)
- the stage
- the PR host, merge method and reviewers
- `review_model`, `review_effort`, `review_spec_model`, `review_spec_effort`, `fix_model`, `fix_effort` and `fix_max_iterations`
- `agent_timeout` and the poll settings
- the deploy settings, when the stage is `verify_deploy`
- the authenticated account names
- the log path

Every setting in the block is tagged with where its value came from: `--set`, `env`, `.shiprc`, `.codereviewrc` (a project's review keys) or `default`. Overridden values are marked so they stand out:

```
  ship_stage      merge            ← --set
  review_model    sonnet           ← env CR_REVIEW_MODEL
  review_effort   high             .shiprc
  fix_model       sonnet           default
```

## Overrides

Every `.shiprc` key can be overridden for a single run without editing the file. Both the review settings and the ship settings can be overridden.

Precedence, highest first:

1. **`--set key=value`** on `ship.sh`. It can be repeated. From make, use `SET='key=value;key=value'`, separated by `;`. `STAGE=merge` (make) and `--stage merge` (script) are shorthand for `ship_stage`.
2. **Environment variable `CR_<KEY>`**: the key in uppercase with a `CR_` prefix. Examples: `CR_SHIP_STAGE`, `CR_REVIEW_MODEL`, `CR_DEPLOY_SMOKE`. The prefix keeps generic keys like `enabled` and `command` from colliding with unrelated variables.
3. **`.shiprc`**, or the project's `.codereviewrc` for review keys when it has its own review tooling.
4. **The built-in default.**

Rules:

- **Unknown keys fail.** `--set revew_model=sonnet` or `CR_REVEW_MODEL` stops the plan and names the closest known key. The environment check looks at every `CR_*` variable, so a typo can't be silently ignored.
- **Values are validated the same way no matter where they come from.** An invalid override fails preflight exactly as a bad `.shiprc` value would.
- **Empty means default.** `--set review_model=` or `CR_REVIEW_MODEL=` falls back to the built-in default, not to `.shiprc`.
- **Overrides reach the review.** `ship.sh` exports each resolved `--set` value as `CR_<KEY>` before pushing, so the pre-push `code-review.sh` in the worktree sees it. The worktree's copy of `.shiprc` isn't edited.
- **Plain `git push` honors `CR_*` too** in a scaffolded repo, because `rc_get` in `common.sh` checks the environment first. `CR_REVIEW_MODEL=sonnet git push` works without `make ship`.
- **Values with spaces work.** For example, `SET='deploy_name=Brady Sales Agent (dev)'`. A value that itself contains `;` has to be set through `CR_<KEY>` or `.shiprc`.
- **Overrides are per run.** They're never written back to `.shiprc`. To change a setting permanently, edit the file or use `make ship-stage`.

The skill always passes overrides as `--sets ...`, never as environment variables. That keeps them visible in the command shown in the permission prompt, and it keeps the command matching the `ship.sh --detach` ask rule.

## Retention

At each kickoff, delete ship directories whose `finished_at` is more than `ship_log_retention_days` days old (default 30). The age comes from `finished_at`, not from file modification times. Also remove the worktree and local snapshot branch left behind by each pruned ship.

Pruning never removes a ship that's still running (no `finished_at`, or a live `pid`), and never removes whatever `latest` points to. Setting `ship_log_retention_days=0` turns pruning off.

## The /ship skill

The skill file is `~/.claude/skills/ship/SKILL.md`, a user-level skill.

| Command | What it does |
|---|---|
| `/ship [stage] [key=value ...]` | If the stage is `open_pr` and no reviewers were given, asks for reviewers first (see Plan and confirm). Runs `ship.sh --plan [--stage <stage>] [--sets ...]` and posts the config block. If preflight passed, runs `ship.sh --detach --yes --id <id> --expect-sha <sha> --expect-config <hash>` with the same `--stage` and `--sets`. Plain-language requests map to `--sets` too: "ship it with sonnet for the review" becomes `--sets 'review_model=sonnet'`. After a denied prompt, a follow-up like "same, but with `review_effort=max`" starts a fresh plan with the previous overrides plus the new one. The `ask` permission prompt on that command is the single confirmation. If it's denied, the skill reports the ship was cancelled and stops. If it's approved, the skill starts a Monitor on the ship's `events` file and posts one line per event. At the end, posts a summary. On failure, it reads the copied review report or `ship.log` and explains what went wrong and how to fix it |
| `/ship status [id]` | Summarizes every running ship and the last few finished ones from their `status.json` files |
| `/ship stop [id]` | Kills the background process, sets the state to `stopped`, and reports anything left behind: an open PR, armed auto-complete, the worktree |

The job keeps running if the session closes. When `ship_notify=desktop` is set, the script also sends a desktop notification when the ship passes, fails or stops (default `none`). It uses `osascript` on macOS, a toast through `powershell.exe` on Windows (Git Bash or WSL), and `notify-send` on Linux, and does nothing when none of them is installed.

## Review base

`code-review.sh` bases a branch's first review on `origin/<default branch>`. Scaffolded projects default to `develop`, so that's already right for them. Repos installed by hand may still default to `main`, and there a PR into `develop` would be reviewed against the wrong base. `ship.sh` exports `REVIEW_BASE_BRANCH=develop`, and `code-review.sh` uses it in place of `default_branch()` in its merge-base fallback. Plain `git push` behavior doesn't change.

## Documented intent

The skill's `code-review.sh` doesn't assume the scaffold's `docs/` layout. `lib/review-docs.sh` picks the documents that state the repo's intended behavior from the shipped commit, so the plan and the review see the same set:

- `review_docs=auto` (the default) takes whichever of `docs`, `doc`, `ARCHITECTURE.md`, `DESIGN.md` and `README.md` exist.
- `review_docs=<paths>`, space-separated, names them. A named path missing from the commit is left out, and preflight warns about it.
- `review_docs=none` says the repo has no such documents.

Every prompt (both review passes, the fixer and the verifier) names the documents found and ranks the sources: documents > tests > code. With no documents the order is tests > code. A `CLAUDE.md` that sets a different order wins. In practice:

- Pass 1 flags tests weakened, skipped or deleted to make changed code pass.
- Pass 2 starts from any design overview among the documents and reads per-flow specs where they exist. It requires a doc update only when a change leaves a statement in the documents wrong; a change the documents don't describe needs none. With no documents it checks only the recorded decisions, and missing documentation is not a finding.
- The fixer fixes the code, not the test, unless a higher source shows the test is wrong, and quotes that source when it changes a test.
- The verifier keeps a finding open when it was "fixed" by changing a test no higher source called wrong.

The review prints the documents it uses and lists them in the report header. A scaffolded repo's pre-push hook runs its own review, which reads `docs/` and gets the order from its `CLAUDE.md`.

## Concurrency

Ships of different branches, or of different commits on one branch, run side by side, each in its own worktree.

- **Ledger lock.** Every write to `.git/code-review-ledger`, from `ship.sh` or from `code-review.sh`, holds a lock. The lock is a `mkdir` of `.git/code-review-ledger.lock`, since macOS has no `flock` by default. A writer retries for up to 30 seconds. It records its PID in the lock directory and removes the lock on exit through a trap. A lock whose PID is no longer alive counts as stale and is removed.
- **No duplicate ships.** Kickoff refuses a second ship of the same source branch and HEAD SHA while the first is running (see Plan and confirm, step 2). The message names the running ship's ID and suggests `/ship status`.
- **Merge conflicts in `develop`.** Two ships can each pass review and still conflict once the first merges. The host blocks the second PR, the ship records that as a `waiting` reason, and it fails at `pr_poll_timeout` with the PR left open.

## Configuration

The ship's settings are in `.shiprc` at the repo root, which stays out of git and per-developer. In a repo with its own review tooling, the review keys stay in the project's `.codereviewrc`, which its pre-push hook reads; `rc_file_of` in `lib/ship-config.sh` picks the file for each key. Everywhere else `.shiprc` has every key.

**First run.** A plan, kickoff or `set-ship-stage.sh` in a repo without `.shiprc` creates it as a copy of `shiprc.template`. Nothing is copied from `.codereviewrc`. Then, unless something already ignores `.shiprc` or the repo tracks it, `.shiprc` is appended to `.gitignore` and committed on the current branch with `git commit -- .gitignore`, so nothing else staged goes in. The line is added but not committed when `.gitignore` has uncommitted changes, HEAD is detached, the branch is `develop`, the target, `main` or `master`, or the commit fails. Each step prints a `NOTE:` line, which `/ship` relays in the session. The plan does this before it reads HEAD, so the commit is part of the ship and kickoff's `--expect-sha` still matches.

**Toolchain detection.** `lib/toolchain.sh` runs next, on a plan or kickoff of a feature ship with the skill's tooling and `review_agent=claude`. For each of `ship_setup` and `fix_checks` that `.shiprc` doesn't set, one `claude -p` call with only `Read`, `Grep` and `Glob` reads the repo's CI config first, then task runners, manifests, lockfiles and docs, and answers with `SETUP:`, `CHECKS:` and `SOURCE:` lines. The values are appended to `.shiprc` under a comment naming the source and date, with a `NOTE:` line; `none` records that there's nothing to run, so detection doesn't repeat. Checks that aren't one command (`cd`, `&`, `|`, redirection, `$(`, a `VAR=value` prefix or `#`) are dropped with a `NOTE:`, because each check becomes an allow rule matched from its start. A failed call or malformed answer saves nothing and prints a `NOTE:`; the next ship tries again, and the `pyproject.toml` defaults apply meanwhile. The e2e tests stub the agent with a fake `claude` on PATH.

These are the ship keys in `.shiprc`:

```
# How far /ship and make ship go after review and push:
# push | open_pr | merge | verify_deploy
ship_stage=open_pr

# Days to keep finished ship logs; 0 keeps them forever.
ship_log_retention_days=30

# none | desktop (desktop notification on macOS, Windows or Linux when the ship finishes)
ship_notify=none

# Reviewers added to the PR, comma-separated. Empty adds none.
# GitHub: usernames or org/team. ADO: emails/UPNs or [Project]\Team.
pr_reviewers=

# --- verify_deploy (dev only) ---
deploy_pipeline=                 # ADO pipeline name or ID, or GitHub workflow name
deploy_provider=                 # cloud_run | agent_runtime (or agent_engine)
deploy_project=                  # dev GCP project ID
deploy_region=us-central1
deploy_name=                     # Cloud Run service or Agent Runtime display name
deploy_match=                    # sha | time (default time)
deploy_proxy=false               # Cloud Run: smoke through gcloud run services proxy
deploy_smoke=                    # e.g. SMOKE_TEST_REQUIRE_LIVE=1 make test-e2e
deploy_run_grace=300
deploy_poll_timeout=3600
deploy_smoke_timeout=900
```

Repos on the skill's review tooling also have `review_docs` (see Documented intent) and `fix_checks`.

The review's agents run headless with `--permission-mode dontAsk`, so a command outside their allow list is denied, never prompted. Both review passes and the verifier may run `git diff`, `git log`, `git show`, `git status` and each `fix_checks` command; the fixer may also edit files. An allow rule matches a command from its start, so the prompts tell every agent to run each check as written, on its own, from the repo root. They also tell the reviewers not to change files, since they share the worktree, and to say when a finding rests on behavior they couldn't run because no checks are configured.

The existing keys stay: `pr_host`, `pr_merge_method`, `pr_self_approve`, `pr_poll_interval`, `pr_poll_timeout` and `ship_fix_retries`.

**Migration:** none. `pr_automation` is removed, and ship keys left in `.codereviewrc`, `pr_automation` included, are ignored. A developer who changed them sets them again in the new `.shiprc`.

## Scaffold changes

1. **New question: SHA tagging.** Asked only for GCP projects with a deploy target: "Tag deploys with the commit SHA? (Recommended: yes)".
   - In agents-cli mode, the edit goes into the generated GitHub workflows: each `agents-cli deploy` gets `--labels commit=${GITHUB_SHA::12}`. That labels both an Agent Runtime and a Cloud Run revision. It's asked only for Full depth, since Prototype depth has no CI deploy. The scaffold confirms the edit landed. If the expected code isn't found, it skips the edit and reports that.
   - A hand-written Cloud Run deploy can instead use `--revision-suffix=$(git rev-parse --short=12 HEAD)`; `/ship` accepts either.
   - The answer sets `deploy_match` (`sha` or unset) in the generated `.codereviewrc`.

2. **Prefilled deploy settings.** When the scaffold knows the target (agents-cli's `-d`, Full depth only, since Prototype has no pipeline), it fills in `deploy_provider`, `deploy_name` and `deploy_region` (from `agents-cli-manifest.yaml`). `deploy_pipeline`, `deploy_project` and `deploy_smoke` are left for the developer.

3. **Setup prompt.** `make setup` asks for the stage, defaulting to `open_pr`, instead of the yes/no auto-PR prompt.

4. **`develop` as the default branch.**
   - **Locally.** Step 6 makes the initial commit on `main`, then creates `develop` from it and checks it out.
   - **On the remote.** The scaffold creates no remote, so the report and `README.md` give the follow-up commands for the first push: push both branches, then `gh repo edit --default-branch develop` or `az repos update --repository <repo> --default-branch develop`, then `git remote set-head origin develop`.
   - **Preflight.** Preflight fails if `origin/develop` doesn't exist. It warns, but doesn't fail, if `origin/HEAD` isn't `develop`, and the warning includes the same commands.

## Existing repos

Any repo works without setup: the skill's own review tooling runs (see Packaging). A repo can still copy the scaffold's tooling and include `ship.mk` to get the pre-push hook and the `make` targets. `/ship push` works as a dry run: preflight lists anything missing.

## Example: Brady.Adk.SalesAgent

```
ship_stage=verify_deploy
pr_host=az
deploy_pipeline=azure-pipelines-dev
deploy_provider=agent_engine
deploy_project=it-arch-tool-registry-dev-8075
deploy_region=us-central1
deploy_name=Brady Sales Agent (dev)
deploy_match=time
deploy_smoke=SMOKE_TEST_REQUIRE_LIVE=1 make test-e2e
```

A merge that only changes files outside the dev pipeline's path filters (for example `docs/`) ends at `verify_deploy: skipped (no deploy triggered)`.

## Prod releases

`/ship main` (or `master`, or `make ship BRANCH=main`) releases `develop` into that branch.

1. **Confirm.** The skill asks, in one call, whether this is a prod deploy that merges `develop` into the branch, and whether to self-approve and auto-merge. No to the first cancels. The second sets the stage: no is `open_pr` (the recommended answer), yes is `merge` with `pr_self_approve=true`. A prod release ignores `ship_stage` from `.shiprc`: with no `--stage` or `CR_SHIP_STAGE`, it resolves to `open_pr` and the plan tags it `prod default`. `push` and `verify_deploy` fail preflight.
2. **Plan.** Preflight fetches `develop` and the target, then freezes `origin/develop`'s tip as `SHIP_SHA`. It fails if `develop` has nothing the target doesn't, or if a PR from `develop` into the target is already open. It warns if the target has commits `develop` lacks, such as a hotfix. It skips the feature-branch checks: the current checkout, the pre-push hook and uncommitted changes don't matter.
3. **Release notes.** The skill drafts notes from `git log --no-merges origin/<target>..<SHIP_SHA>` and the recorded decisions, writes them to `<git-common-dir>/ship/release-notes.md`, and plans again with `--notes-file`. The notes' hash is part of `SHIP_CONFIG`, along with the target, so an edit after the plan makes kickoff refuse. Kickoff copies the file to `.git/ship/<id>/release-notes.md`. Without `--notes-file`, the description is the commit subjects (minus `Apply code review auto-fix`) and the decisions.
4. **Run.** There's no snapshot branch, no worktree and no push. The stages run from the checkout and touch only the PR host and remote refs. The PR goes from `develop` into the target, titled `prod 🚀`, with the notes and a footer naming the commit. `merge` always uses a merge commit (`pr_merge_method` applies to feature ships only) and never deletes `develop`. On GitHub, `gh pr merge --match-head-commit` pins the merge to `SHIP_SHA`. On both hosts, each poll fails the ship if the PR's head is no longer `SHIP_SHA`, since merging would release commits nobody planned.

GitHub doesn't let you approve your own PR, so with self-approve the merge still waits for any review that branch protection requires.

## Out of scope

- Prod deploy verification.
- Repos with more than one deploy target.
- An MCP server interface. It could wrap `ship.sh` later if the agent's git and PR permissions need to be restricted.
- Running ships somewhere other than the developer's machine.
- Copying gitignored files other than `.shiprc` and `.codereviewrc` into the worktree. A smoke test that needs `.env` or similar has to get its settings some other way.
- A command that installs the ship pipeline into existing repos.

## Implementation notes

Decisions the build made where the draft was silent, and additions to it.

- **Reviewer question.** The skill learns the resolved stage and configured reviewers from a first `ship.sh --plan` run, asks, then plans again with `pr_reviewers` in `--sets`. The plan is read-only, so running it twice costs a few seconds. "No reviewers" passes `pr_reviewers=` so configured reviewers are cleared for that run.
- **Plan output.** The block ends with `SHIP_ID=`, `SHIP_SHA=`, `SHIP_CONFIG=` and `SHIP_PREFLIGHT=passed|failed` lines for the skill to read. The config hash is the first 12 characters of `git hash-object` over every resolved `key=value`.
- **Watching.** `ship.sh --watch [id]` (`make ship-watch`) prints each event as `<stage> <state>: <message>`, except a kickoff whose message has comma-separated details: that prints `kickoff passed` and then each detail on its own `- ` line, because the Monitor truncates long lines. It exits when the ship finishes (0 on passed), or when its process dies without finishing. The skill runs it under a Monitor. The finish event is written before `finished_at`, so a watcher that stops at `finished_at` has always seen it.
- **Event stages.** Events use `kickoff`, `push` (which covers the review and the push), `open_pr`, `merge`, `verify_deploy` and `finish`.
- **Stop.** `ship_stop` collects the ship's descendant processes before sending TERM to `ship.sh`, since they can't be found from its PID once it exits, then sends TERM to them too (the push, the review agents, the smoke test). `ship.sh` records `stopped` from its TERM trap. If it hasn't within 15 seconds, the stop command kills it and records the state itself. With no ID and more than one ship running, it lists them and asks for one.
- **Foreground ships** write `pid` too, so duplicate detection and `/ship stop` work for them.
- **Re-shipping a failed commit.** The snapshot branch name is fixed by the commit, so a failed or stopped ship's kept branch would block a second ship of the same commit. Preflight warns that the new ship replaces them, and kickoff removes that worktree and branch (keeping its logs). A `ship/*` branch no ship owns fails preflight. So does a snapshot branch already on `origin`: an earlier ship of the same commit pushed it, and pushing again is rejected if that ship committed an auto-fix. Preflight names the branch to delete once its PR is merged or closed.
- **Ledger.** A passed or pruned ship's snapshot entry is removed from the ledger, so it doesn't grow by one line per ship. `ledger_set <branch> ""` deletes an entry.
- **Detached runner.** The background process runs this skill's `scripts/ship.sh` from the ship's worktree, so with the project's tooling it sources the snapshot's own `scripts/lib/common.sh` and `scripts/decisions.sh`. A `git pull` in the skill while a ship runs changes the code under it; that's accepted. It inherits the exported `CR_*` overrides, and reads everything else from `status.json`.
- **Makefile variables** (`STAGE`, `SET`, `ID`, `SHA`, `CONFIG`, `DETACH`, `YES`) are read only when their `$(origin)` is `command line`, so a stray `YES=1` in the environment can't skip the terminal prompt. `SET` and `STAGE` reach `ship.sh` through the shell (`"$SET"`), so values with spaces and parentheses survive.
- **Deploy polling** reuses `pr_poll_interval` between polls; there's no separate key.
- **JSON parsing.** `status.json` is written one `"key": "value"` per line with the config object last, so the scripts read and update it with `sed` and `awk`. gcloud and Vertex AI responses are parsed with `uv run --no-project python`, so the plan never syncs the project env and nothing needs `jq`.
- **Agent Runtime checks** list up to 100 reasoning engines per project and pick the one whose `displayName` is `deploy_name`; the health check is that it exists. The `commit` label and `updateTime` are read from the engine resource. Confirming those fields (engine versus runtime revision) against Brady.Adk.SalesAgent is still open.
- **Cloud Run SHA tagging** by revision suffix makes a redeploy of the same commit fail, because the revision name `<service>-<sha12>` already exists. The `commit` label that agents-cli mode uses doesn't have that problem.
- **ADO approval gates** are detected best-effort from the build timeline (`Checkpoint.Approval` records in progress). GitHub reports them directly as run status `waiting`.

