# ship reference

How a ship runs, every setting, and where the files live. The README covers the basics; `docs/install.md` covers setup; `docs/spec.md` is the design spec.

## How a ship runs

1. A plan prints the resolved settings, each tagged with where its value came from, and checks everything the stage needs: CLI logins, reviewers, the deploy target. It creates no branch or worktree. On a repo's first ship it also creates `.shiprc`, commits the `.gitignore` line, and detects the toolchain (see [First ship in a repo](#first-ship-in-a-repo)).
2. You confirm. In a session that's the permission prompt on `ship.sh --detach`. In a terminal it's `Proceed? [y/N]`. Denying leaves everything as it was.
3. The commit at HEAD is frozen as the branch `ship/<branch>-<sha7>` (`ship/<target>/<branch>-<sha7>` when the target isn't `develop`), checked out in a new worktree at `../<repo>.ship-<id>`. Commits you make afterwards don't join this ship.
4. The worktree runs `ship_setup`, then reviews and pushes the snapshot branch (see [Which review runs](#which-review-runs)). If the auto-fix clears every REQUIRED finding, the ship commits the fix and pushes again, up to `ship_fix_retries` times. If REQUIRED findings are still open, the ship fails and the report is copied to `.git/ship/<id>/code-review-report.md`.
5. The ship then goes as far as `ship_stage`. Each stage includes the ones before it.

| Stage | What runs |
|---|---|
| `push` | Stops after the push |
| `open_pr` | Opens a PR from the snapshot branch into `develop` and adds `pr_reviewers`. The default |
| `merge` | Self-approves, arms auto-merge (squash, delete the source branch), and waits for the merge |
| `verify_deploy` | Waits for the dev pipeline run on the merge commit, checks the service is healthy and running that commit, and runs the smoke test |

Your checkout and local branches are never touched. After a merge the final message suggests `git branch -d <branch>`, and nothing else changes. A passed ship removes its worktree and local snapshot branch. A failed or stopped one keeps both for inspection.

A background ship keeps running if the session closes. Each ship's `status.json`, `events`, `ship.log` and review report live in `.git/ship/<id>/`. They're deleted `ship_log_retention_days` (default 30) after the ship finishes.

At `open_pr` without named reviewers, `/ship` asks whether to add any. At `merge` and above the PR is approved and merged right away, so the plan warns if `pr_reviewers` is set.

### Commands

```bash
/ship                        # plan, confirm, run in the background, report each stage
/ship merge                  # a different stage for this run
/ship staging                # target a branch other than develop
/ship main                   # prod release: PR from develop into main
/ship review_model=sonnet    # any .shiprc key, for this run
/ship status                 # running and recent ships
/ship stop                   # stop a running ship and list what it left (open PR, armed auto-merge)

make ship-plan STAGE=merge SET='review_model=sonnet'   # the plan only
make ship STAGE=merge                                  # plan, prompt, then run in the foreground
make ship BRANCH=staging                               # target another branch
make ship-stage STAGE=open_pr                          # change your default stage
```

## Which review runs

- Any repo: `ship.sh` runs this skill's `scripts/code-review.sh` in the ship worktree before each push. The push then runs the repo's own hooks, if it has any. The review reads `CLAUDE.md` when there is one and checks changes against the repo's documents (see [Documents and source of truth](#documents-and-source-of-truth)). It works with no documents at all.
- A repo the scaffold skill created: its `scripts/lib/common.sh` sets `ship_contract`, and its pre-push hook runs its own `scripts/code-review.sh` on every push, so `ship.sh` relies on the hook and doesn't review twice. The `ship_contract` value has to match the one in `scripts/lib/ship-config.sh`. A mismatch stops the ship with a message saying which side to update. A `scripts/lib/common.sh` without `ship_contract` is treated as unrelated, and the skill's review runs.

The decision trailers in the PR description come from the repo's `scripts/decisions.sh` when it has one, and from this skill's copy otherwise.

`ship.sh` writes review reports to files under `working/`. When the repo doesn't already ignore or track them, it adds those files to `.git/info/exclude`, which stays local and is never committed. It names the report files rather than all of `working/`, so a repo that keeps its own files in `working/` still commits fixes to them. The auto-fix commit leaves the reports and the settings files out either way, so a tracked `.shiprc` with personal edits isn't pushed.

## Documents and source of truth

The skill's review ranks its sources: the repo's documents first, then tests, then code. Documents state intended behavior. Tests encode it where the documents say nothing. Code only shows what happens now. A repo with no documents gets tests over code. If `CLAUDE.md` sets a different order, the review follows `CLAUDE.md`.

`review_docs` sets which files count as documents:

- `auto`, the default, takes whichever of `docs`, `doc`, `ARCHITECTURE.md`, `DESIGN.md` and `README.md` the commit has.
- A space-separated list names them, for example `review_docs=specs/ ADR.md`. The plan warns about any path the commit doesn't have.
- `none` says the repo has no such documents.

The plan's `docs` line shows what was found, and the review report lists it too. The order changes the review in four ways:

- The review flags tests weakened, skipped or deleted to make changed code pass.
- It asks for a doc update only when a change makes a documented statement wrong. With no documents, missing documentation is never a finding.
- The fixer fixes the code, not the test, unless a document shows the test is wrong.
- The verifier rejects a fix that only edits a test.

A scaffolded repo's own review reads `docs/` and gets the same order from the scaffold's `CLAUDE.md`.

## First ship in a repo

The ship's settings live in `.shiprc` at the repo root. The first `/ship` in a repo without one creates it from `shiprc.template`, with the default settings. Nothing is copied from an existing `.codereviewrc`: ship settings left there are ignored, so set them again in `.shiprc`. The old `pr_automation` key is gone; use `ship_stage`.

The same run adds `.shiprc` to `.gitignore` and commits that change on your branch, with nothing else in the commit. It skips the commit, leaving the line in place, when `.gitignore` already has uncommitted changes of yours, when HEAD is detached, or when you're on `develop`, `main` or `master`. Nothing is added when something already ignores `.shiprc` or the repo tracks it. Each of these steps prints a `NOTE:` line, and `/ship` passes it on in the session.

The first ship also works out how to install the repo and run its checks, filling in `ship_setup` and `fix_checks`. `ship_setup` is the command run in a new worktree before the review, so the fixer and the repo's git hooks have their dependencies. `fix_checks` lists the lint and test commands the reviewers run to confirm a finding and the fixer runs to check its work.

One agent call reads the repo's CI config (GitHub Actions, Azure Pipelines, GitLab and others), Makefile or other task runner, `package.json` scripts, `.pre-commit-config.yaml`, lockfiles and README, and picks the commands CI runs. It can only read files. The result goes into `.shiprc` under a comment naming where it came from, and a `NOTE:` line shows it. Later ships read it from there and make no agent call. `none` means there's nothing to run. A check that isn't a single command (one with `cd`, `&&`, a pipe or a `VAR=value` prefix) is left out, because the review's agents may only run a check exactly as written. If detection fails, nothing is saved and the next ship tries again. Detection skips any key you've already set, runs only with the skill's own review and `review_agent=claude`, and doesn't run for a prod release.

Without a saved value, `ship_setup` falls back to `uv sync -q` and `fix_checks` to `uv run pre-commit;uv run pytest` when there's a `pyproject.toml`, and to nothing otherwise. Preflight fails when the program `ship_setup` starts with isn't on PATH, and warns for a missing check program. To set them yourself for a Node repo:

```
ship_setup=npm ci
fix_checks=npm run lint;npm test
```

In a repo the scaffold skill created, the review keys stay in the project's `.codereviewrc`, since its own pre-push review reads them there. Everywhere else every key, review keys included, goes in `.shiprc`.

`.shiprc` is kept out of git and is personal to your machine. How far your ships go shouldn't change for a teammate because they pulled a commit. Every default is built into the scripts, so the template's values are the defaults.

## Overrides

Any `.shiprc` key can be changed for one run without editing the file. Highest priority first:

1. `/ship key=value` in a session, `make ship SET='key=value;key=value'`, or `ship.sh --set key=value`. `STAGE=merge` is shorthand for `ship_stage`.
2. The environment variable `CR_<KEY>`, for example `CR_REVIEW_MODEL=sonnet`.
3. `.shiprc` (a scaffolded repo's `.codereviewrc` for review keys).
4. The built-in default.

An unknown key fails the plan and names the closest known one. An empty value means the default. In a scaffolded repo, plain `git push` honors `CR_*` too, so `CR_REVIEW_MODEL=sonnet git push` works. Overrides are never written back; `make ship-stage` is the one command that edits the file.

## Settings

| Key | Values | Default |
|-----|--------|---------|
| `ship_stage` | `push`, `open_pr`, `merge`, `verify_deploy` | `open_pr` |
| `ship_setup` | command run in a new worktree before the review; `none` runs nothing | detected on the first ship; else `uv sync -q` with a `pyproject.toml`, else none |
| `fix_checks` | `;`-separated lint and test commands the reviewers and fixer may run (skill review only); `none` runs nothing | detected on the first ship; else `uv run pre-commit;uv run pytest` with a `pyproject.toml`, else none |
| `review_docs` | `auto`, `none`, or space-separated paths of the documents the review checks against (skill review only) | `auto` |
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

## Prod releases

`/ship main` (or `master`) releases `develop` into it. It asks two things first: whether this is a prod deploy that merges `develop` into `main`, and whether to self-approve and auto-merge. The default answer to the second is no, which stops at an open PR for a human to approve and merge. `ship_stage` in `.shiprc` doesn't apply to prod.

The release is `origin/develop` at the commit the plan saw. There's no worktree and no push, because every change was reviewed on its way into `develop`. `/ship` drafts release notes from the commits and recorded decisions since `main` and shows them before the permission prompt. The PR is titled `prod 🚀` with the notes as its description. It merges with a merge commit, so `main` and `develop` don't diverge, and it never deletes `develop`. If `develop` moves while the PR waits, the ship fails rather than release commits nobody planned. `verify_deploy` checks the dev deploy only, so a prod release goes no further than `merge`.

From a terminal, `make ship BRANCH=main NOTES=<file>` does the same with your own notes file. Without `NOTES`, the description is a generated list of commit subjects.

## Deploy verification

`verify_deploy` checks the dev environment only, once the `deploy_*` keys in `.shiprc` are filled in. It looks for a `deploy_pipeline` run on `develop` for the merge commit. If none appears within `deploy_run_grace` seconds, the pipeline's path filters excluded the change: the stage is recorded as skipped and the ship passes.

Once the run succeeds, the target has to be healthy. A Cloud Run service needs Ready=True and 100% of traffic on its latest ready revision; an Agent Runtime has to exist under `deploy_name`. It also has to be this commit. With `deploy_match=sha` the Cloud Run revision must be named `<service>-<sha12>` or carry a `commit=<sha12>` label, and the Agent Runtime must carry a `commit=<sha12>` label. Otherwise it must have been created or updated after the run started.

The smoke test (`deploy_smoke`) runs in the ship's worktree with `DEPLOY_URL`, `DEPLOY_RESOURCE` and `DEPLOY_SHA` set, and its exit code decides the result. A smoke test that skips and exits 0 when it can't reach the target makes this check meaningless, so set its require-live flag (for example `SMOKE_TEST_REQUIRE_LIVE=1`). For a private Cloud Run service, `deploy_proxy=true` points `DEPLOY_URL` at a local `gcloud run services proxy`.

## Squash merges and decisions

`/ship` squashes by default. When the branch has decision trailers, it writes the squash commit message itself, listing the commits and then every trailer, so nothing is lost. A squash merge from the host's web UI does not do this. If you turn squash merging off on the host, set `pr_merge_method=merge` (or `rebase`), or the merge stage fails to arm auto-merge.

## Hooks in the ship worktree

The push, and the auto-fix commit, run the repo's hooks in the ship's worktree. In a worktree, git sets `GIT_DIR` to `.git/worktrees/<name>` for every hook it runs; in your main checkout it doesn't. A hook that runs git against another repository inherits that variable, so git looks in the wrong repo. `terraform init` with `git::` module sources fails with `invalid ref` for every module, and installs from git URLs or hook scripts that clone or `cd` elsewhere fail in similar ways. The ship then reports `git push failed`.

Fix it in the hook by clearing the variables before the command that runs git:

```yaml
entry: bash -euc 'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; terraform -chdir=infra init -backend=false'
```

Commit the fix on the branch you ship, since the ship runs the hooks from its snapshot. Hooks that only check the current files (linters, type checkers, tests) aren't affected, and pre-commit already clears these variables for its own downloads.

## Layout

| Path | What it is |
|---|---|
| `SKILL.md` | The `/ship` skill |
| `scripts/ship.sh` | Plans and runs one ship |
| `scripts/lib/ship-config.sh` | Picks the project's review tooling or this skill's, checks `ship_contract`, adds the ship keys and defaults |
| `scripts/code-review.sh`, `scripts/decisions.sh`, `scripts/lib/common.sh` | The review, decision trailers and shared helpers, used in repos without their own. Copies of the scaffold skill's templates, with `fix_checks` added, documents found by `review_docs`, and settings read from `.shiprc` |
| `scripts/lib/review-docs.sh` | Finds the documents the skill's review checks against |
| `scripts/lib/toolchain.sh` | Detects the install and check commands on a repo's first ship |
| `scripts/lib/ship-status.sh`, `scripts/lib/ship-deploy.sh` | Status and event helpers; deploy verification |
| `scripts/set-ship-stage.sh` | Writes `ship_stage` into the project's `.shiprc` |
| `ship.mk` | The `make ship*` targets a project includes |
| `shiprc.template` | What a new `.shiprc` starts as |
| `docs/spec.md` | The design spec |
| `tests/e2e.sh` | End-to-end checks up to the push stage, in throwaway repos: `bash tests/e2e.sh` |
