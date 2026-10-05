# ship

A Claude Code skill that ships a branch in the background. `/ship` reviews the branch, fixes what the review finds, pushes it, then opens a PR, merges it, and verifies the dev deploy, as far as the configured stage goes. It works from its own git worktree, so you keep editing while it runs. `/ship main` releases `develop` to prod through a PR with drafted release notes.

## Install

```bash
git clone git@github.com:quidmonkey/ship-skill.git ~/.claude/skills/ship
```

You rarely need to run this yourself. The [scaffold skill](https://github.com/quidmonkey/scaffold-skill) clones it when it creates a project, and a scaffolded project's `make setup` clones it on a teammate's machine. To update, run `git -C ~/.claude/skills/ship pull`.

## What a project needs

The skill holds the ship pipeline. The project holds the review half, which the scaffold skill writes:

- `scripts/code-review.sh`, installed as the pre-push hook. A ship pushes from its worktree, and this hook reviews that push.
- `scripts/decisions.sh`, which the PR description and squash message use.
- `scripts/lib/common.sh`, the shared config and review-ledger helpers. Its `ship_contract` value has to match the one in `scripts/lib/ship-config.sh`. A mismatch stops the ship with a message saying which side to update.
- A `Makefile` that includes `ship.mk`, and `ask` permission rules for `make ship`.

### Adding /ship to a project

For a repo the scaffold skill didn't create:

1. Copy `scripts/code-review.sh`, `scripts/decisions.sh` and `scripts/lib/common.sh` from the scaffold skill's `templates/`, and add the code-review pre-push hook from its `templates/pre-commit-config.yaml`.
2. Add this to the `Makefile`, after its first target:

   ```make
   SHIP_SKILL ?= $(HOME)/.claude/skills/ship
   -include $(SHIP_SKILL)/ship.mk
   ```

3. Append `codereviewrc.ship` to `.codereviewrc`, and gitignore `.codereviewrc`. Every key has a built-in default, so this step only documents the settings.
4. Add `Bash(make ship)`, `Bash(make ship *)`, `Bash(bash *.claude/skills/ship/scripts/ship.sh*)` and `Bash(*.claude/skills/ship/scripts/ship.sh*)` to `ask` in `.claude/settings.json`.
5. Run `/ship push` once. Preflight lists anything still missing.

A repo whose default branch is still `main` works too. `ship.sh` bases the first review on `develop` either way.

## Shipping a branch

Run `/ship` in a Claude Code session, or `make ship` in a terminal. The ship runs from its own git worktree, so you can keep editing while it works.

1. A read-only plan prints the resolved settings, each tagged with where its value came from, and checks everything the stage needs: CLI logins, reviewers, the deploy target. Nothing is created yet.
2. You confirm. In a session that's the permission prompt on `make ship`. In a terminal it's `Proceed? [y/N]`. Denying leaves everything as it was.
3. The commit at HEAD is frozen as the branch `ship/<branch>-<sha7>` (`ship/<target>/<branch>-<sha7>` when the target isn't `develop`), checked out in a new worktree at `../<repo>.ship-<id>`. Commits you make afterwards don't join this ship.
4. The worktree pushes the snapshot branch, which runs the pre-push review there. If the auto-fix clears every REQUIRED finding, the ship commits the fix and pushes again, up to `ship_fix_retries` times. If REQUIRED findings are still open, the ship fails and the report is copied to `.git/ship/<id>/code-review-report.md`.
5. The ship then goes as far as `ship_stage`. Each stage includes the ones before it.

| Stage | What runs |
|---|---|
| `push` | Stops after the push |
| `open_pr` | Opens a PR from the snapshot branch into `develop` and adds `pr_reviewers`. The default |
| `merge` | Self-approves, arms auto-merge (squash, delete the source branch), and waits for the merge |
| `verify_deploy` | Waits for the dev pipeline run on the merge commit, checks the service is healthy and running that commit, and runs the smoke test |

A ship targets `develop` unless you name another branch (`/ship staging`, `make ship BRANCH=staging`). Naming `main` or `master` starts a prod release instead; see [Prod releases](#prod-releases). Your checkout and local branches are never touched: after a merge the final message suggests `git branch -d <branch>`, and nothing else changes. A passed ship removes its worktree and local snapshot branch. A failed or stopped one keeps both for inspection.

```bash
/ship                        # plan, confirm, run in the background, report each stage
/ship merge                  # a different stage for this run
/ship staging                # target a branch other than develop
/ship main                   # prod release: PR from develop into main (see below)
/ship review_model=sonnet    # any .codereviewrc key, for this run
/ship status                 # running and recent ships
/ship stop                   # stop a running ship and list what it left (open PR, armed auto-merge)

make ship-plan STAGE=merge SET='review_model=sonnet'   # the plan only
make ship STAGE=merge                                  # plan, prompt, then run in the foreground
make ship-stage STAGE=open_pr                          # change your default stage
```

A background ship keeps running if the session closes. Each ship's `status.json`, `events`, `ship.log` and review report live in `.git/ship/<id>/`. They're deleted `ship_log_retention_days` (default 30) after the ship finishes.

At `open_pr` without named reviewers, `/ship` asks whether to add any. At `merge` and above the PR is approved and merged right away, so the plan warns if `pr_reviewers` is set.

### Prod releases

`/ship main` (or `master`) releases `develop` into it. It asks two things first: whether this is a prod deploy that merges `develop` into `main`, and whether to self-approve and auto-merge. The default answer to the second is no, which stops at an open PR for a human to approve and merge. `ship_stage` in `.codereviewrc` doesn't apply to prod.

The release is `origin/develop` at the commit the plan saw. There's no worktree and no push, because every change was reviewed on its way into `develop`. `/ship` drafts release notes from the commits and recorded decisions since `main` and shows them before the permission prompt. The PR is titled `prod 🚀` with the notes as its description. It merges with a merge commit, so `main` and `develop` don't diverge, and it never deletes `develop`. If `develop` moves while the PR waits, the ship fails rather than release commits nobody planned. `verify_deploy` checks the dev deploy only, so a prod release goes no further than `merge`.

From a terminal, `make ship BRANCH=main NOTES=<file>` does the same with your own notes file. Without `NOTES`, the description is a generated list of commit subjects.

### Overrides

Any `.codereviewrc` key can be changed for one run without editing the file. Highest priority first:

1. `/ship key=value` in a session, `make ship SET='key=value;key=value'`, or `ship.sh --set key=value`. `STAGE=merge` is shorthand for `ship_stage`.
2. The environment variable `CR_<KEY>`, for example `CR_REVIEW_MODEL=sonnet`.
3. `.codereviewrc`.
4. The built-in default.

An unknown key fails the plan and names the closest known one. An empty value means the default. Plain `git push` honors `CR_*` too, so `CR_REVIEW_MODEL=sonnet git push` works. Overrides are never written back; `make ship-stage` is the one command that edits the file.

### Deploy verification

`verify_deploy` checks the dev environment only, after filling in the `deploy_*` keys in `.codereviewrc`. It looks for a `deploy_pipeline` run on `develop` for the merge commit. If none appears within `deploy_run_grace` seconds, the pipeline's path filters excluded the change: the stage is recorded as skipped and the ship passes.

Once the run succeeds, the target has to be healthy. A Cloud Run service needs Ready=True and 100% of traffic on its latest ready revision; an Agent Runtime has to exist under `deploy_name`. It also has to be this commit. With `deploy_match=sha` the Cloud Run revision must be named `<service>-<sha12>` or carry a `commit=<sha12>` label, and the Agent Runtime must carry a `commit=<sha12>` label. Otherwise it must have been created or updated after the run started.

The smoke test (`deploy_smoke`) runs in the ship's worktree with `DEPLOY_URL`, `DEPLOY_RESOURCE` and `DEPLOY_SHA` set, and its exit code decides the result. A smoke test that skips and exits 0 when it can't reach the target makes this check meaningless, so set its require-live flag (for example `SMOKE_TEST_REQUIRE_LIVE=1`). For a private Cloud Run service, `deploy_proxy=true` points `DEPLOY_URL` at a local `gcloud run services proxy`.

### Ship settings

| Key | Values | Default |
|-----|--------|---------|
| `ship_stage` | `push`, `open_pr`, `merge`, `verify_deploy` | `open_pr` |
| `ship_fix_retries` | times one ship commits an auto-fix and pushes again | `1` |
| `ship_log_retention_days` | days to keep finished ship logs; `0` keeps them | `30` |
| `ship_notify` | `none`, `desktop` (desktop notification on macOS, Windows or Linux when a ship passes, fails or stops) | `none` |
| `pr_host` | `gh`, `az` | detected from `origin` |
| `pr_reviewers` | comma-separated GitHub users or `org/team`; ADO emails or `[Project]\Team` | none |
| `pr_merge_method` | `squash`, `merge`, `rebase` | `squash` |
| `pr_self_approve` | `true`, `false`; a host that rejects self-review makes it a no-op | `true` |
| `pr_poll_interval` / `pr_poll_timeout` | seconds between polls / before the merge stage gives up | `15` / `1800` |
| `deploy_pipeline` | ADO pipeline name or ID, or GitHub workflow name | none |
| `deploy_provider` | `cloud_run`, `agent_runtime` (or its earlier name, `agent_engine`) | none |
| `deploy_project` / `deploy_region` | dev GCP project / region | none / `us-central1` |
| `deploy_name` | Cloud Run service or Agent Runtime display name | none |
| `deploy_match` | `sha`, `time` | `time` |
| `deploy_proxy` | `true`, `false` | `false` |
| `deploy_smoke` | smoke test command | none |
| `deploy_run_grace` / `deploy_poll_timeout` / `deploy_smoke_timeout` | seconds | `300` / `3600` / `900` |

`.codereviewrc` is gitignored and personal to your machine. How far your ships go is your call, and it shouldn't change for a teammate because they pulled a commit. Every default is built into the scripts, so a clone with no `.codereviewrc` behaves like the scaffolded file. A file that still has the old `pr_automation` key and no `ship_stage` is read as `merge` (true) or `push` (false), with a notice.

### Squash merges and decisions

`/ship` squashes by default. When the branch has decision trailers, it writes the squash commit message itself, listing the commits and then every trailer, so nothing is lost. A squash merge from the host's web UI does not do this. If you turn squash merging off on the host, set `pr_merge_method=merge` (or `rebase`), or the merge stage fails to arm auto-merge.

## Layout

| Path | What it is |
|---|---|
| `SKILL.md` | The `/ship` skill |
| `scripts/ship.sh` | Plans and runs one ship |
| `scripts/lib/ship-config.sh` | Loads the project's `common.sh`, checks `ship_contract`, adds the ship keys and defaults |
| `scripts/lib/ship-status.sh`, `scripts/lib/ship-deploy.sh` | Status and event helpers; deploy verification |
| `scripts/set-ship-stage.sh` | Writes `ship_stage` into the project's `.codereviewrc` |
| `ship.mk` | The `make ship*` targets a project includes |
| `codereviewrc.ship` | The ship section of `.codereviewrc` |
| `docs/spec.md` | The design spec |

The `version` in `SKILL.md` follows semver. The scaffold skill names the minimum version it needs and asks before pulling a newer one.
