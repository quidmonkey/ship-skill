# ship reference

How a ship runs, every setting, and where the files live. The README covers the basics; `docs/install.md` covers setup; `docs/spec.md` is the design spec.

## How a ship runs

1. A plan prints the settings this ship's stage uses, plus any other setting that isn't at its default, each tagged with where its value came from, and checks everything the stage needs: CLI logins, reviewers, `deploy_check`. It creates no branch or worktree. On a repo's first ship it also creates `.shiprc`, excludes it from git, and detects the toolchain (see [First ship in a repo](#first-ship-in-a-repo)).
2. You confirm. In a session that's the permission prompt on `ship.sh --detach`. In a terminal it's `Proceed? [y/N]`. Denying leaves everything as it was.
3. The commit at HEAD is frozen as the branch `ship/<branch>-<sha7>` (`ship/<target>/<branch>-<sha7>` when the target isn't `develop`), checked out in a new worktree at `../<repo>.ship-<id>`. Commits you make afterwards don't join this ship.
4. The worktree runs `ship_setup`, then reviews and pushes the snapshot branch (see [The review](#the-review)). If the auto-fix clears every REQUIRED finding, the ship commits the fix and pushes again, once. If REQUIRED findings are still open, the ship fails and the report is copied to `.git/ship/<id>/code-review-report.md`.
5. The ship then goes as far as `ship_stage`. Each stage includes the ones before it.

| Stage | What runs |
|---|---|
| `push` | Stops after the push |
| `open_pr` | Opens a PR from the snapshot branch into `develop` and adds `pr_reviewers`. The default |
| `merge` | Self-approves, arms auto-merge (squash, delete the source branch), and waits for the merge |
| `verify_deploy` | Runs `deploy_check` against the merge commit (see [Deploy verification](#deploy-verification)) |

Your checkout and local branches are never touched. After a merge the final message suggests `git branch -d <branch>`, and nothing else changes. A passed ship removes its worktree and local snapshot branch. A failed or stopped one keeps both for inspection.

A ship that failed or was stopped after its push can be retried. In a session, fix the cause (an expired `az login`, say) and tell Claude to try again. `ship.sh --retry [<id>]` resumes the ship at the first stage that didn't pass, with the settings it started with, so the review and push aren't repeated. It first checks the PR host login and that origin still has the pushed commit. With no ID it takes the latest ship. A prod release can be retried too, unless `develop` has moved since the plan. If the review blocked the push, commit a fix and `/ship` again instead. Planning a new ship of a commit that a failed ship already pushed fails with a pointer to the retry.

A background ship keeps running if the session closes. Each ship's `status.json`, `events`, `ship.log` and review report live in `.git/ship/<id>/`. They're deleted 30 days after the ship finishes.

The plan shows `pr_reviewers` before you confirm. To change them for one run, deny the prompt and ask again with `pr_reviewers=<list>` (or "have Jane review"). At `merge` and above the PR is approved and merged right away, so the plan warns if `pr_reviewers` is set.

### Commands

```bash
/ship                        # plan, confirm, run in the background, report each stage
/ship merge                  # a different stage for this run
/ship staging                # target a branch other than develop
/ship main                   # prod release: PR from develop into main
/ship review_model=sonnet    # any .shiprc key, for this run
/ship status                 # running and recent ships
/ship stop                   # stop a running ship and list what it left (open PR, armed auto-merge)
/ship retry                  # resume a failed or stopped ship where it stopped

make ship-plan STAGE=merge SET='review_model=sonnet'   # the plan only
make ship STAGE=merge                                  # plan, prompt, then run in the foreground
make ship BRANCH=staging                               # target another branch
make ship-stage STAGE=open_pr                          # change your default stage
```

## The review

`ship.sh` runs this skill's `scripts/code-review.sh` in the ship worktree before each push. The push then runs the repo's own hooks, if it has any. The review reads `CLAUDE.md` when there is one and checks changes against the repo's documents (see [Documents and source of truth](#documents-and-source-of-truth)). It works with no documents at all. The decision trailers in the PR description come from this skill's `scripts/decisions.sh`.

`ship.sh` writes review reports to files under `working/`. When the repo doesn't already ignore or track them, it adds those files to `.git/info/exclude`, which stays local and is never committed. It names the report files rather than all of `working/`, so a repo that keeps its own files in `working/` still commits fixes to them. The auto-fix commit leaves the reports and `.shiprc` out either way, so a tracked `.shiprc` with personal edits isn't pushed.

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

## First ship in a repo

The ship's settings live in `.shiprc` at the repo root. The first `/ship` in a repo without one creates it from `shiprc.template`, with the default settings, and prints a `NOTE:` line that `/ship` passes on in the session.

`.shiprc` is kept out of git by a line in `.git/info/exclude`, the repo's local ignore file. That file lives inside `.git`, so it's never committed or pushed, and the ship never commits anything on your branch to set itself up. Each developer's first ship adds the line on their own machine. Nothing is added when something already ignores `.shiprc` (a `.gitignore` line, say) or the repo tracks it. To see or remove the line, open `.git/info/exclude`; in a worktree it's the one in the main checkout's `.git`.

The first ship also works out how to install the repo and run its checks, filling in `ship_setup` and `fix_checks`. `ship_setup` is the command run in a new worktree before the review, so the fixer and the repo's git hooks have their dependencies. `fix_checks` lists the lint and test commands the reviewers run to confirm a finding and the fixer runs to check its work.

One agent call reads the repo's CI config (GitHub Actions, Azure Pipelines, GitLab and others), Makefile or other task runner, `package.json` scripts, `.pre-commit-config.yaml`, lockfiles and README, and picks the commands CI runs. It can only read files. The result goes into `.shiprc` under a comment naming where it came from, and a `NOTE:` line shows it. Later ships read it from there and make no agent call. `none` means there's nothing to run. A check that isn't a single command (one with `cd`, `&&`, a pipe or a `VAR=value` prefix) is left out, because the review's agents may only run a check exactly as written. If detection fails, nothing is saved and the next ship tries again. Detection skips any key you've already set and doesn't run for a prod release.

Without a saved value, `ship_setup` falls back to `uv sync -q` and `fix_checks` to `uv run pre-commit;uv run pytest` when there's a `pyproject.toml`, and to nothing otherwise. Preflight fails when the program `ship_setup` starts with isn't on PATH, and warns for a missing check program. To set them yourself for a Node repo:

```
ship_setup=npm ci
fix_checks=npm run lint;npm test
```

`.shiprc` is kept out of git and is personal to your machine. How far your ships go shouldn't change for a teammate because they pulled a commit. Every default is built into the scripts, so the template's values are the defaults.

## Overrides

Any `.shiprc` key can be changed for one run without editing the file. Highest priority first:

1. `/ship key=value` in a session, `make ship SET='key=value;key=value'`, or `ship.sh --set key=value`. `STAGE=merge` is shorthand for `ship_stage`.
2. The environment variable `CR_<KEY>`, for example `CR_REVIEW_MODEL=sonnet`.
3. `.shiprc`.
4. The built-in default.

An unknown key fails the plan and names the closest known one. An empty value means the default. Overrides are never written back; `make ship-stage` is the one command that edits the file.

## Settings

| Key | Values | Default |
|-----|--------|---------|
| `ship_stage` | `push`, `open_pr`, `merge`, `verify_deploy` | `open_pr` |
| `ship_setup` | command run in a new worktree before the review; `none` runs nothing | detected on the first ship; else `uv sync -q` with a `pyproject.toml`, else none |
| `fix_checks` | `;`-separated lint and test commands the reviewers and fixer may run; `none` runs nothing | detected on the first ship; else `uv run pre-commit;uv run pytest` with a `pyproject.toml`, else none |
| `review_docs` | `auto`, `none`, or space-separated paths of the documents the review checks against | `auto` |
| `review_model` / `review_effort` | model for the review's first pass, and its effort: `low`, `medium`, `high`, `xhigh`, `max`, `default` | `opus` / `high` |
| `fix_max_iterations` | auto-fix rounds after a failed review; `0` turns auto-fix off | `2` |
| `agent_timeout` | seconds per review or fix agent call | `900` |
| `ship_notify` | `none`, `desktop` (desktop notification on macOS, Windows or Linux when a ship passes, fails or stops) | `none` |
| `pr_host` | `gh`, `az` | detected from `origin` |
| `pr_reviewers` | comma-separated GitHub users or `org/team`; ADO emails or `[Project]\Team` | none |
| `pr_merge_method` | `squash`, `merge`, `rebase`; a prod release always uses a merge commit | `squash` |
| `pr_self_approve` | `true`, `false`; a host that rejects self-review makes it a no-op | `true` |
| `pr_poll_timeout` | seconds the merge stage waits for the merge | `1800` |
| `deploy_check` | command `verify_deploy` runs after the merge (see [Deploy verification](#deploy-verification)) | none |
| `deploy_timeout` | seconds `deploy_check` may run | `3600` |

Some behavior is fixed rather than set. The review's second pass, the fix verifier and the fixer use `sonnet` at `medium` effort. A ship commits an auto-fix and pushes again at most once. The merge stage polls every 15 seconds. Finished ship logs are kept for 30 days.

## Prod releases

`/ship main` (or `master`) releases `develop` into it. It uses the same settings as a feature ship: `ship_stage`, `pr_reviewers`, `pr_self_approve` and `deploy_check` come from `.shiprc` or the invocation, so `/ship main open_pr` stops at an open PR. The plan shows the target and every setting, and approving the permission prompt is the human review of the release. `ship_stage=push` fails the plan, since a prod release has nothing to push.

The release is `origin/develop` at the commit the plan saw. There's no worktree and no push, because every change was reviewed on its way into `develop`. `/ship` drafts release notes from the commits and recorded decisions since `main` and shows them before the permission prompt. The PR is titled `prod 🚀` with the notes as its description. It always merges with a merge commit, whatever `pr_merge_method` says, so `main` and `develop` don't diverge, and it never deletes `develop`. If `develop` moves while the PR waits, the ship fails rather than release commits nobody planned. At `verify_deploy`, `deploy_check` runs from your checkout with `DEPLOY_BRANCH=main`.

From a terminal, `make ship BRANCH=main NOTES=<file>` does the same with your own notes file. Without `NOTES`, the description is a generated list of commit subjects.

## Deploy verification

`verify_deploy` runs the `deploy_check` command from `.shiprc` once the PR has merged. It runs in the ship's worktree (your checkout for a prod release) with two variables set:

- `DEPLOY_SHA`: the merge commit.
- `DEPLOY_BRANCH`: the branch the PR merged into, so one command can check dev for `develop` and prod for `main`.

The command waits for that commit's deploy and checks it however your project needs: a pipeline run, a health endpoint, a smoke test. Exit 0 passes the stage. Any other exit fails the ship, and the command's output is in `ship.log`. It's stopped after `deploy_timeout` seconds. A check that exits 0 when it can't reach the deploy makes this stage meaningless, so make it fail in that case. A failed check can be retried once the cause is fixed. When a merge doesn't trigger a deploy (path filters, for example), the command decides what that means; exiting 0 with a message passes the ship.

```
deploy_check=./scripts/check-deploy.sh
```

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
| `scripts/lib/ship-config.sh` | Loads the helpers, creates `.shiprc` and keeps it and the review's files out of git |
| `scripts/code-review.sh`, `scripts/decisions.sh`, `scripts/lib/common.sh` | The review, decision trailers, and shared helpers and setting defaults |
| `scripts/lib/review-docs.sh` | Finds the documents the review checks against |
| `scripts/lib/toolchain.sh` | Detects the install and check commands on a repo's first ship |
| `scripts/lib/ship-status.sh` | Status, event and log helpers |
| `scripts/set-ship-stage.sh` | Writes `ship_stage` into the project's `.shiprc` |
| `ship.mk` | The `make ship*` targets a project includes |
| `shiprc.template` | What a new `.shiprc` starts as |
| `docs/spec.md` | The design spec |
| `tests/e2e.sh` | End-to-end checks in throwaway repos, with a stub `claude` and a stub `gh`: `bash tests/e2e.sh` |
