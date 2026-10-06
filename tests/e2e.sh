#!/usr/bin/env bash
# End-to-end checks of ship.sh in throwaway repos with a local bare origin.
# No real PR host and no Claude calls: gh and claude are stubs on PATH. The
# review runs this skill's real code-review.sh, and the fake claude's verdict
# comes from $sb/mode.
#
#   bash tests/e2e.sh
set -u

skill=$(cd "$(dirname "$0")/.." && pwd)
ship="$skill/scripts/ship.sh"
sb=$(mktemp -d "${TMPDIR:-/tmp}/ship-e2e.XXXXXX")
trap 'rm -rf "$sb"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
ko() {
    echo "FAIL  $1"
    printf '%s\n' "$2" | tail -n 25 | sed 's/^/      /'
    failed=$((failed + 1))
}
# expect <name> <regex> <output>
expect() {
    if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else ko "$1 (wanted /$2/)" "$3"; fi
}
# refute <name> <regex> <output>
refute() {
    if printf '%s' "$3" | grep -qE -- "$2"; then ko "$1 (didn't want /$2/)" "$3"; else ok "$1"; fi
}
# assert <name> <detail-on-failure> <command...>
assert() {
    local name=$1 detail=$2
    shift 2
    if "$@"; then ok "$name"; else ko "$name" "$detail"; fi
}
# refute_cmd <name> <detail-on-failure> <command...> — the command must fail.
refute_cmd() {
    local name=$1 detail=$2
    shift 2
    if "$@"; then ko "$name" "$detail"; else ok "$name"; fi
}
on_origin() { git ls-remote --exit-code --heads origin "$1" > /dev/null; }
no_extra_worktrees() { [ -z "$(git worktree list | sed 1d)" ]; }
latest() { readlink .git/ship/latest; }
snapshot_of() { sed -n 's/.*"snapshot_branch": *"\([^"]*\)".*/\1/p' ".git/ship/$1/status.json"; }

# A fake claude on PATH, so no check calls the real one. It records its
# arguments, answers toolchain discovery from $sb/discover (failing when that
# file is missing), and appends every review and fix prompt to $sb/prompts.
# Verification passes; the fix pass appends "fixed" to app.txt; a review's
# verdict comes from $sb/mode, and "autofix" passes once the fix has run.
mkdir -p "$sb/bin"
cat > "$sb/bin/claude" <<EOF
printf '%s\n' "\$@" >> "$sb/claude-args"
prompt=""
prev=""
for arg in "\$@"; do
    [ "\$prev" = -p ] && prompt=\$arg
    prev=\$arg
done
case "\$prompt" in
    *"Work out how this repository installs"*) [ -f "$sb/discover" ] || exit 1; cat "$sb/discover"; exit 0 ;;
esac
printf '%s\n' "\$prompt" >> "$sb/prompts"
case "\$prompt" in
    *"verifying the fix pass"*) echo "- RESOLVED"; echo "VERDICT: PASS"; exit 0 ;;
    *"You are the fix pass"*)
        echo fixed >> app.txt
        [ -f working/notes.md ] && echo fixed >> working/notes.md
        echo "Fix summary"; echo "FIXED app.txt:1"
        exit 0
        ;;
esac
mode=\$(cat "$sb/mode" 2>/dev/null || echo pass)
if [ "\$mode" = pass ] || { [ "\$mode" = autofix ] && grep -q fixed app.txt; }; then
    echo "No findings."; echo "VERDICT: PASS"
else
    echo "- **REQUIRED** — app.txt:1 — broken, fails on every input"; echo "VERDICT: FAIL"
fi
EOF
chmod +x "$sb/bin/claude"
export PATH="$sb/bin:$PATH"
discoveries() { grep -c "Work out how this repository installs" "$sb/claude-args" 2>/dev/null; }

# new_repo <name> — a repo on feature/x, one commit ahead of origin/develop,
# with ship_setup and fix_checks set in .shiprc so no plan runs discovery.
new_repo() {
    git init -q --bare -b develop "$sb/$1-origin.git"
    git init -q -b develop "$sb/$1"
    cd "$sb/$1" || exit 1
    git config user.email t@example.com
    git config user.name Tester
    git remote add origin "$sb/$1-origin.git"
    echo hello > app.txt
    git add -A
    git commit -qm init
    git push -q -u origin develop 2>/dev/null
    git remote set-head origin develop
    git checkout -qb feature/x
    echo change >> app.txt
    git commit -qam "Change app" -m "Decision: keep app.txt plain text"
    printf 'ship_setup=none\nfix_checks=none\n' > .shiprc
    echo pass > "$sb/mode"
}

# --- a plain repo: no Makefile, no scripts/, no hooks ---------------------------

echo "== plain repo"
new_repo plain
mv .shiprc "$sb/stubs"

out=$(bash "$ship" --plan --stage push 2>&1)
expect "first plan creates .shiprc" "NOTE: created \.shiprc with the default ship settings, kept out of git by \.git/info/exclude" "$out"
assert "the new .shiprc is the template" "$(diff .shiprc "$skill/shiprc.template")" cmp -s .shiprc "$skill/shiprc.template"
expect "defaults apply" "review_model +opus +default" "$out"
expect "no ship_setup without pyproject.toml" "ship_setup +\(none\) +default" "$out"
expect "a failed discovery says the next ship retries" "NOTE: couldn't detect this repo's install and check commands; the next ship tries again" "$out"
refute "a failed discovery saves nothing" "^(ship_setup|fix_checks)=" "$(cat .shiprc)"
cat "$sb/stubs" >> .shiprc
out=$(bash "$ship" --plan --stage push 2>&1)
expect "settings are read from .shiprc" "ship_setup +none +\.shiprc" "$out"
expect "plan passes with no project tooling" "SHIP_PREFLIGHT=passed" "$out"
expect "the first plan commits nothing" "^Change app$" "$(git log -1 --format=%s)"
assert "no .gitignore is written" "$(cat .gitignore 2>&1)" [ ! -f .gitignore ]
expect ".shiprc is excluded locally" "^\.shiprc$" "$(cat .git/info/exclude)"
assert ".shiprc stays out of git status" "$(git status --porcelain)" [ -z "$(git status --porcelain)" ]
out=$(bash "$ship" --plan --stage push 2>&1)
refute "a later plan has no notes" "NOTE:" "$out"
refute "uv isn't required" "uv isn't on PATH" "$out"
expect "fix_checks is shown" "fix_checks" "$out"
expect "plan shows no docs found" "docs +\(none: none of docs doc ARCHITECTURE.md DESIGN.md README.md exists\) ← review_docs=auto" "$out"
assert "plan creates no worktree" "$(git worktree list)" no_extra_worktrees

out=$(bash "$ship" --plan --stage push --sets 'review_modle=sonnet' 2>&1)
expect "unknown key suggests the closest" "Did you mean 'review_model'" "$out"
out=$(bash "$ship" --plan --stage push --sets 'review_agent=custom' 2>&1)
expect "a removed setting is unknown" "unknown setting 'review_agent'" "$out"
out=$(bash "$ship" --plan --stage push 2>&1)
refute "the plan hides settings at their defaults" "agent_timeout|pr_poll_timeout" "$out"
out=$(bash "$ship" --plan --stage push --sets 'agent_timeout=60' 2>&1)
expect "the plan shows a changed setting" "agent_timeout +60 +← --set" "$out"
out=$(bash "$ship" --plan --resume 20990101-000000-abcdef0 2>&1)
expect "--plan with --resume is refused" "can't be combined" "$out"
out=$(bash "$ship" --status --stop 2>&1)
expect "two modes are refused" "can't be combined" "$out"
out=$(bash "$ship" --stage push < /dev/null 2>&1)
expect "no terminal and no --yes refuses" "no terminal to confirm" "$out"

plan=$(bash "$ship" --plan --stage push 2>&1)
id=$(printf '%s' "$plan" | sed -n 's/^SHIP_ID=//p')
sha=$(printf '%s' "$plan" | sed -n 's/^SHIP_SHA=//p')
cfg=$(printf '%s' "$plan" | sed -n 's/^SHIP_CONFIG=//p')
out=$(bash "$ship" --yes --id "$id" --expect-sha "$sha" --expect-config bad --stage push 2>&1)
expect "a changed config refuses" "changed since the plan" "$out"
out=$(bash "$ship" --yes --id "$id" --expect-sha "$sha" --expect-config "$cfg" --stage push 2>&1)
rc=$?
expect "passing ship ships to push" "shipped to push" "$out"
expect "the review ran" "Code review PASSED" "$out"
expect "the review prints its documents" "Documents of intended behavior: \(none" "$out"
prompts=$(cat "$sb/prompts")
expect "no docs: tests outrank code" "highest authority first: tests > code" "$prompts"
expect "no docs: missing docs aren't a finding" "Missing documentation is not a finding" "$prompts"
refute "no docs: docs/design.md isn't assumed" "docs/design.md\\. If" "$prompts"
expect "no checks: the reviewer is told it can't run the code" "so you can't run the$" "$prompts"
assert "passing ship exits 0 (rc=$rc)" "$out" [ "$rc" -eq 0 ]
snap="ship/feature/x-${sha:0:7}"
assert "origin has $snap" "$(git ls-remote origin)" on_origin "$snap"
assert "passed ship removes its worktree" "$(git worktree list)" no_extra_worktrees
assert "checkout is still feature/x" "$(git status)" [ "$(git symbolic-ref --short HEAD)" = feature/x ]
assert "checkout is clean" "$(git status)" [ -z "$(git status --porcelain)" ]
excl=$(cat .git/info/exclude)
expect "the review report is excluded locally" "^working/code-review-report.md$" "$excl"
refute "working/ itself isn't excluded" "^working/?$" "$excl"
assert "report copied to the ship dir" "$(ls ".git/ship/$id")" [ -f ".git/ship/$id/code-review-report.md" ]
out=$(bash "$ship" --status 2>&1)
expect "status lists the ship" "$id" "$out"
out=$(bash "$ship" --plan --stage push 2>&1)
expect "the same commit can't ship twice" "origin already has" "$out"

echo more >> app.txt
git commit -qam "Second change"
echo block > "$sb/mode"
out=$(bash "$ship" --yes --stage push --sets 'fix_max_iterations=0' 2>&1)
rc=$?
expect "a blocking review fails the ship" "the review blocked the push" "$out"
assert "blocked ship exits non-zero" "$out" [ "$rc" -ne 0 ]
bid=$(latest)
expect "report has the finding" "broken, fails on every input" "$(cat ".git/ship/$bid/code-review-report.md" 2>&1)"
refute_cmd "blocked ship didn't push" "$(git ls-remote origin)" on_origin "$(snapshot_of "$bid")"
refute_cmd "failed ship keeps its worktree" "no worktree left" no_extra_worktrees

echo autofix > "$sb/mode"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "auto-fix commits and retries" "retry 1 of 1" "$out"
refute "auto-fix doesn't warn about ignored paths" "paths are ignored" "$out"
expect "auto-fix ship passes" "shipped to push" "$out"
asnap=$(snapshot_of "$(latest)")
expect "origin tip is the auto-fix commit" "Apply code review auto-fix" "$(git log -1 --format=%s "origin/$asnap" 2>&1)"
files=$(git show --name-only --format= "origin/$asnap")
expect "auto-fix commit has the fix" "^app.txt$" "$files"
refute "auto-fix commit has no working/ or settings" "working/|shiprc" "$files"
assert "leftover worktree replaced and cleaned" "$(git worktree list)" no_extra_worktrees

# A pre-commit hook that rewrites files fails the first auto-fix commit; its
# changes are staged and the second try goes through.
echo again >> app.txt
git commit -qam "Change again"
printf '#!/bin/sh\ngrep -q formatted app.txt && exit 0\necho formatted >> app.txt\nexit 1\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
out=$(bash "$ship" --yes --stage push 2>&1)
expect "auto-fix ship passes a rewriting hook" "shipped to push" "$out"
fsnap=$(snapshot_of "$(latest)")
expect "the auto-fix commit has the hook's rewrite" "^formatted$" "$(git show "origin/$fsnap:app.txt" 2>&1)"
echo once-more >> app.txt
git commit -qam "Change once more" --no-verify
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > .git/hooks/pre-commit
out=$(bash "$ship" --yes --stage push 2>&1)
expect "a rejected auto-fix commit names the hook" "the repo's pre-commit hook rejected the auto-fix commit" "$out"
rm .git/hooks/pre-commit

# The repo's own pre-push hook still runs after the review.
echo third >> app.txt
git commit -qam "Third change"
echo pass > "$sb/mode"
printf '#!/bin/sh\necho "repo hook says no" >&2\nexit 1\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
out=$(bash "$ship" --yes --stage push 2>&1)
expect "the repo's pre-push hook runs" "repo hook says no" "$out"
expect "a hook failure is reported as a push failure" "git push failed" "$out"
expect "a hook failure points at the worktree GIT_DIR note" "Hooks in the ship worktree" "$out"
rm .git/hooks/pre-push

out=$(bash "$ship" --yes --stage push --detach 2>&1)
expect "--detach starts in the background" "started in the background" "$out"
did=$(printf '%s' "$out" | sed -n 's/^SHIP_ID=//p')
out=$(bash "$ship" --watch "$did" 2>&1)
expect "--watch follows to the end" "shipped to push" "$out"

echo fourth >> app.txt
git commit -qam "Fourth change"
printf '#!/bin/sh\nsleep 60\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
out=$(bash "$ship" --yes --stage push --detach 2>&1)
sid=$(printf '%s' "$out" | sed -n 's/^SHIP_ID=//p')
sleep 3
out=$(bash "$ship" --plan --stage push 2>&1)
expect "plan refuses while the same commit ships" "already shipping" "$out"
out=$(bash "$ship" --stop "$sid" 2>&1)
expect "--stop stops it" "Stopped ship $sid" "$out"
rm .git/hooks/pre-push

out=$(bash "$skill/scripts/set-ship-stage.sh" merge 2>&1)
expect "set-ship-stage writes the stage" "ship_stage=merge written to \.shiprc" "$out"
expect "set-ship-stage writes .shiprc" "^ship_stage=merge$" "$(grep '^ship_stage=' .shiprc | tail -n 1)"
refute "settings stay out of git status" "shiprc" "$(git status --porcelain)"
bash "$skill/scripts/set-ship-stage.sh" push > /dev/null 2>&1
assert "exclude lines aren't duplicated" "$(cat .git/info/exclude)" \
    [ "$(grep -cxF working/code-review-report.md .git/info/exclude)" = 1 ]

# --- a documented repo: the review finds docs/ and README.md ----------------------

echo "== documented repo"
new_repo documented
mkdir -p docs
echo "App appends lines." > docs/design.md
echo "# App" > README.md
git add -A
git commit -qm "Add docs"
out=$(bash "$ship" --plan --stage push 2>&1)
expect "plan shows the docs found" "docs +docs, README.md ← review_docs=auto" "$out"
out=$(bash "$ship" --plan --stage push --sets 'review_docs=docs/ spec/missing.md' 2>&1)
expect "named review_docs are shown" "docs +docs ← review_docs=docs/ spec/missing.md" "$out"
expect "a missing review_docs path warns" "leaves them out: spec/missing.md" "$out"
out=$(bash "$ship" --plan --stage push --sets 'review_docs=none' 2>&1)
expect "review_docs=none shows no docs" "docs +\(none: review_docs=none\)" "$out"
: > "$sb/prompts"
echo autofix > "$sb/mode"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "documented ship passes" "shipped to push" "$out"
prompts=$(cat "$sb/prompts")
expect "prompts list the docs" "^- docs$" "$prompts"
expect "docs outrank tests and code" "those documents > tests > code" "$prompts"
expect "the fixer fixes code, not tests" "fix the code, not the test" "$prompts"
expect "the verifier rejects test-only fixes" "by changing a test that no higher source" "$prompts"
expect "the report names the docs" "Documents: docs, README.md" "$(cat ".git/ship/$(latest)/code-review-report.md")"

# --- a repo that tracks its own working/: fixes there are committed ----------------

echo "== tracked working/"
new_repo trackedwork
mkdir -p working
echo notes > working/notes.md
git add working
git commit -qm "Track working notes"
echo autofix > "$sb/mode"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "tracked-working ship passes" "shipped to push" "$out"
files=$(git show --name-only --format= "origin/$(snapshot_of "$(latest)")")
expect "auto-fix commit has the tracked working/ fix" "^working/notes.md$" "$files"
refute "auto-fix commit leaves the review reports out" "code-review|autofix-pending" "$files"

# --- a repo that tracks .shiprc: personal edits stay out of commits ----------------

echo "== tracked .shiprc"
new_repo tracked
git add -f .shiprc
git commit -qm "Track ship settings"
echo "# personal edit" >> .shiprc
echo autofix > "$sb/mode"
out=$(bash "$ship" --yes --stage push 2>&1)
refute "a tracked .shiprc gets no notes" "NOTE:" "$out"
expect "tracked-settings ship passes" "shipped to push" "$out"
files=$(git show --name-only --format= "origin/$(snapshot_of "$(latest)")")
expect "auto-fix commit has the fix" "^app.txt$" "$files"
refute "auto-fix commit leaves the tracked .shiprc out" "shiprc" "$files"
refute "a tracked .shiprc isn't excluded" "shiprc" "$(cat .git/info/exclude)"
assert "a tracked .shiprc isn't added to .gitignore" "$(cat .gitignore 2>&1)" [ ! -f .gitignore ]

# --- a Python repo: ship_setup syncs the worktree --------------------------------

echo "== python repo"
new_repo py
: > .shiprc
printf '[project]\nname = "py"\nversion = "0.1.0"\nrequires-python = ">=3.10"\ndependencies = []\n' > pyproject.toml
git add pyproject.toml
git commit -qm "Add pyproject"
out=$(bash "$ship" --plan --stage push 2>&1)
expect "ship_setup defaults to uv sync" "ship_setup +uv sync -q" "$out"
expect "fix_checks defaults to the uv checks" "fix_checks +uv run pre-commit;uv run pytest" "$out"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "the worktree is synced" "Setting up the worktree: uv sync -q" "$out"
expect "python ship passes" "shipped to push" "$out"
out=$(bash "$ship" --plan --stage push --sets 'ship_setup=false' 2>&1)
expect "ship_setup can be overridden" "ship_setup +false" "$out"

# --- toolchain discovery: the first ship works out ship_setup and fix_checks -------

echo "== toolchain discovery"
new_repo toolchain
# No settings, so the plan discovers the toolchain.
: > .shiprc
cat > "$sb/discover" <<'EOF'
Found the commands in CI.
SETUP: git --version
CHECKS: git status;cd sub && make test;FOO=1 npm test
SOURCE: .github/workflows/ci.yml
EOF
: > "$sb/claude-args"
out=$(bash "$ship" --plan --stage push 2>&1)
expect "discovery notes what it saved" "NOTE: detected ship_setup=git --version and fix_checks=git status from \.github/workflows/ci\.yml\. Saved in \.shiprc\.$" "$out"
expect "discovery notes the dropped checks" "NOTE: left out of fix_checks .*: cd sub && make test; FOO=1 npm test\.$" "$out"
expect "discovery saves ship_setup" "^ship_setup=git --version$" "$(cat .shiprc)"
expect "discovery saves only single-command checks" "^fix_checks=git status$" "$(cat .shiprc)"
expect "the plan shows the saved setup" "ship_setup +git --version +\.shiprc" "$out"
expect "the discovery agent can only read" "^Read,Grep,Glob$" "$(cat "$sb/claude-args")"
out=$(bash "$ship" --plan --stage push 2>&1)
refute "a later plan doesn't discover again" "NOTE: detected" "$out"
assert "discovery ran once" "$(discoveries)" [ "$(discoveries)" = 1 ]
out=$(bash "$ship" --plan --stage push --sets 'ship_setup=nosuch-setup-tool install;fix_checks=nosuch-check-tool run' 2>&1)
expect "a missing setup program fails preflight" "nosuch-setup-tool isn't on PATH" "$out"
expect "a missing check program only warns" "nosuch-check-tool isn't on PATH, so the review can't run 'nosuch-check-tool run'" "$out"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "the ship runs the detected setup" "Setting up the worktree: git --version" "$out"
expect "discovered ship passes" "shipped to push" "$out"

# --- review_agent=claude: the reviewers may run fix_checks -------------------------

echo "== claude agents"
new_repo agents
cat > .shiprc <<'EOF'
ship_setup=none
fix_checks=make test;npm run lint
EOF
: > "$sb/claude-args"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "claude-agent ship passes" "shipped to push" "$out"
refute "set keys aren't discovered" "NOTE: detected" "$out"
refute "ship_setup=none runs nothing" "Setting up the worktree" "$out"
args=$(cat "$sb/claude-args")
expect "the reviewer may run each check" "^Read,Grep,Glob,Bash\(git diff:\*\).*,Bash\(make test:\*\),Bash\(npm run lint:\*\)$" "$args"
expect "the reviewer is told it may run the checks" "You may run these lint and test commands" "$args"
expect "the prompt lists the checks" "^    npm run lint$" "$args"
expect "the prompt says to run checks exactly as written" "starting exactly as written here" "$args"
refute "the reviewer gets no write tools" "^Read,Edit" "$args"

# --- retry: a ship that fails after the push resumes where it stopped -------------

echo "== retry"
new_repo retry
# A fake gh whose login expires at the first PR create while $sb/gh-expire
# exists. Its PRs merge on the first poll, with the head in $sb/gh-head.
mkdir -p "$sb/ghbin"
cat > "$sb/ghbin/gh" <<EOF
case "\$1 \$2" in
    "auth status") [ -f "$sb/gh-auth" ] ;;
    "api user") echo tester ;;
    "pr create")
        if [ -f "$sb/gh-expire" ]; then rm -f "$sb/gh-auth" "$sb/gh-expire"; echo "gh: login required" >&2; exit 1; fi
        echo "https://github.com/o/r/pull/7"
        ;;
    "pr review" | "pr merge") ;;
    "pr view") printf 'MERGED\\t-\\t%s\\t%s\\n' "\$(cat "$sb/gh-head" 2>/dev/null)" 1111111111111111111111111111111111111111 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$sb/ghbin/gh"
path_before=$PATH
export PATH="$sb/ghbin:$PATH"
touch "$sb/gh-auth" "$sb/gh-expire"
bash "$ship" --plan --stage push > /dev/null 2>&1
out=$(bash "$ship" --yes --stage open_pr --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "an expired login fails open_pr" "auth expired at open_pr" "$out"
expect "the failure says how to retry" "retry from open_pr: ship.sh --retry" "$out"
rid=$(latest)
out=$(bash "$ship" --plan --stage open_pr --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "a new ship of the same commit points at the retry" "Retry it instead: ship.sh --retry $rid" "$out"
out=$(bash "$ship" --retry 2>&1)
expect "retry checks the login" "gh isn't logged in" "$out"
expect "a failed retry check starts nothing" "the ship wasn't retried" "$out"
touch "$sb/gh-auth"
reviews=$(cat "$sb/prompts" 2>/dev/null | wc -l)
out=$(bash "$ship" --retry 2>&1)
expect "retry resumes at open_pr" "resumed in the background at open_pr" "$out"
expect "retry uses the settings the ship started with" "gh +tester" "$out"
out=$(bash "$ship" --watch "$rid" 2>&1)
expect "the retried ship opens the PR" "shipped to open_pr\. PR: https://github.com/o/r/pull/7" "$out"
refute "the watch starts at the retry" "^push " "$out"
assert "the retry doesn't review again" "$(cat "$sb/prompts" 2>/dev/null | wc -l) != $reviews" \
    [ "$(cat "$sb/prompts" 2>/dev/null | wc -l)" = "$reviews" ]
assert "the retried ship removes its worktree" "$(git worktree list)" no_extra_worktrees
out=$(bash "$ship" --retry "$rid" 2>&1)
expect "a passed ship can't be retried" "nothing to retry" "$out"

# --- verify_deploy: deploy_check runs on the merge commit -------------------------

echo "== verify_deploy"
new_repo deploy
git rev-parse HEAD > "$sb/gh-head"
out=$(bash "$ship" --plan --stage verify_deploy --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "verify_deploy needs deploy_check" "verify_deploy needs deploy_check=" "$out"
printf 'deploy_check=sh %s/deploy-check.sh\n' "$sb" >> .shiprc
printf 'echo "$DEPLOY_SHA $DEPLOY_BRANCH" > %s/deploy-env\n' "$sb" > "$sb/deploy-check.sh"
out=$(bash "$ship" --yes --stage verify_deploy --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "a passing deploy_check passes the ship" "shipped to verify_deploy" "$out"
expect "deploy_check gets the merge commit and target" "^1111111111111111111111111111111111111111 develop$" "$(cat "$sb/deploy-env" 2>&1)"
echo more >> app.txt
git commit -qam "Second change"
out=$(bash "$ship" --yes --stage verify_deploy --sets 'pr_host=gh;pr_reviewers=;deploy_check=false' 2>&1)
expect "a failing deploy_check fails the ship" "deploy_check failed \(exit 1\)" "$out"
expect "a failed deploy_check can be retried" "retry from verify_deploy" "$out"

# --- prod release: the same settings as a feature ship ----------------------------

echo "== prod release"
git push -q origin develop:main
git push -q origin feature/x:develop
git fetch -q origin
git rev-parse origin/develop > "$sb/gh-head"
echo ship_stage=push >> .shiprc
out=$(bash "$ship" --plan --target main --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "a prod release at push has nothing to do" "ship_stage=push stops before the PR" "$out"
echo ship_stage=verify_deploy >> .shiprc
out=$(bash "$ship" --plan --target main --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "a prod release takes ship_stage from .shiprc" "ship_stage +verify_deploy +\.shiprc" "$out"
expect "a prod plan passes" "SHIP_PREFLIGHT=passed" "$out"
out=$(bash "$ship" --yes --target main --sets 'pr_host=gh;pr_reviewers=' 2>&1)
expect "a prod release runs to verify_deploy" "shipped to verify_deploy" "$out"
expect "deploy_check gets the prod target" " main$" "$(cat "$sb/deploy-env" 2>&1)"
export PATH=$path_before

echo ""
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
