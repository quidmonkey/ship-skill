#!/usr/bin/env bash
# End-to-end checks of ship.sh up to the push stage, in throwaway repos with a
# local bare origin. No PR host and no Claude calls: the review runs this
# skill's real code-review.sh with review_agent=custom and fix_agent=custom
# stubs, whose verdict comes from $sb/mode.
#
#   bash tests/e2e.sh
set -u

skill=$(cd "$(dirname "$0")/.." && pwd)
ship="$skill/scripts/ship.sh"
scaffold_common="$HOME/.claude/skills/scaffold/templates/scripts/lib/common.sh"
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

# The review stub: verification passes; otherwise the verdict comes from the
# mode, and "autofix" passes once the fix stub has run. Both stubs append the
# prompts they get to $sb/prompts.
cat > "$sb/review.sh" <<EOF
prompt=\$(cat)
printf '%s\n' "\$prompt" >> "$sb/prompts"
case "\$prompt" in *"verifying the fix pass"*) echo "- RESOLVED"; echo "VERDICT: PASS"; exit 0 ;; esac
mode=\$(cat "$sb/mode")
if [ "\$mode" = pass ] || { [ "\$mode" = autofix ] && grep -q fixed app.txt; }; then
    echo "No findings."; echo "VERDICT: PASS"
else
    echo "- **REQUIRED** — app.txt:1 — broken, fails on every input"; echo "VERDICT: FAIL"
fi
EOF
cat > "$sb/fix.sh" <<EOF
cat >> "$sb/prompts"
echo fixed >> app.txt
[ -f working/notes.md ] && echo fixed >> working/notes.md
echo "Fix summary"; echo "FIXED app.txt:1"
EOF

# new_repo <name> [settings-file] — a repo on feature/x, one commit ahead of
# origin/develop, with the stub agents set in .shiprc, or in the named file
# (a scaffolded repo's .codereviewrc, which its .gitignore would ignore).
new_repo() {
    local rc=${2:-.shiprc}
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
    cat > "$rc" <<EOF
review_agent=custom
command=sh $sb/review.sh
fix_agent=custom
fix_command=sh $sb/fix.sh
EOF
    [ "$rc" = .codereviewrc ] && echo .codereviewrc >> .git/info/exclude
    echo pass > "$sb/mode"
}

# --- a plain repo: no Makefile, no scripts/, no hooks ---------------------------

echo "== plain repo"
new_repo plain
mv .shiprc "$sb/stubs"
# An old .codereviewrc isn't read or copied.
cp "$sb/stubs" .codereviewrc
echo .codereviewrc >> .git/info/exclude

out=$(bash "$ship" --plan --stage push 2>&1)
expect "first plan creates .shiprc" "NOTE: created \.shiprc with the default ship settings" "$out"
expect "first plan commits .shiprc to .gitignore" "NOTE: added \.shiprc to \.gitignore and committed it on feature/x" "$out"
assert "the new .shiprc is the template" "$(diff .shiprc "$skill/shiprc.template")" cmp -s .shiprc "$skill/shiprc.template"
expect ".codereviewrc settings aren't used" "review_agent +claude +default" "$out"
cat "$sb/stubs" >> .shiprc
out=$(bash "$ship" --plan --stage push 2>&1)
expect "settings are read from .shiprc" "review_agent +custom +\.shiprc" "$out"
expect "plan passes with no project tooling" "SHIP_PREFLIGHT=passed" "$out"
expect "the .gitignore commit is on the branch" "^Ignore \.shiprc" "$(git log -1 --format=%s)"
expect "the .gitignore commit has only .gitignore" "^\.gitignore$" "$(git show --name-only --format= HEAD)"
expect ".gitignore ignores .shiprc" "^\.shiprc$" "$(cat .gitignore)"
assert ".shiprc stays out of git status" "$(git status --porcelain)" [ -z "$(git status --porcelain)" ]
out=$(bash "$ship" --plan --stage push 2>&1)
refute "a later plan has no notes" "NOTE:" "$out"
expect "plan names the skill's review" "review: the ship skill's code-review.sh" "$out"
expect "no ship_setup without pyproject.toml" "ship_setup +\(none\)" "$out"
refute "uv isn't required" "uv isn't on PATH" "$out"
expect "fix_checks is shown" "fix_checks" "$out"
expect "plan shows no docs found" "docs +\(none: none of docs doc ARCHITECTURE.md DESIGN.md README.md exists\) ← review_docs=auto" "$out"
assert "plan creates no worktree" "$(git worktree list)" no_extra_worktrees

out=$(bash "$ship" --plan --stage push --sets 'review_modle=sonnet' 2>&1)
expect "unknown key suggests the closest" "Did you mean 'review_model'" "$out"
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
assert "passing ship exits 0 (rc=$rc)" "$out" [ "$rc" -eq 0 ]
snap="ship/feature/x-${sha:0:7}"
assert "origin has $snap" "$(git ls-remote origin)" on_origin "$snap"
assert "passed ship removes its worktree" "$(git worktree list)" no_extra_worktrees
assert "checkout is still feature/x" "$(git status)" [ "$(git symbolic-ref --short HEAD)" = feature/x ]
assert "checkout is clean" "$(git status)" [ -z "$(git status --porcelain)" ]
excl=$(cat .git/info/exclude)
expect "the review report is excluded locally" "^working/code-review-report.md$" "$excl"
refute "working/ itself isn't excluded" "^working/?$" "$excl"
refute ".shiprc isn't excluded locally" "shiprc" "$excl"
assert "report copied to the ship dir" "$(ls ".git/ship/$id")" [ -f ".git/ship/$id/code-review-report.md" ]
out=$(bash "$ship" --status 2>&1)
expect "status lists the ship" "$id" "$out"
out=$(bash "$ship" --plan --stage push 2>&1)
expect "the same commit can't ship twice" "origin already has" "$out"

echo more >> app.txt
git commit -qam "Second change"
echo block > "$sb/mode"
out=$(bash "$ship" --yes --stage push --sets 'fix_enabled=false' 2>&1)
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
refute "auto-fix commit has no working/ or settings" "working/|shiprc|codereviewrc" "$files"
assert "leftover worktree replaced and cleaned" "$(git worktree list)" no_extra_worktrees

# The repo's own pre-push hook still runs after the review.
echo third >> app.txt
git commit -qam "Third change"
echo pass > "$sb/mode"
printf '#!/bin/sh\necho "repo hook says no" >&2\nexit 1\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
out=$(bash "$ship" --yes --stage push 2>&1)
expect "the repo's pre-push hook runs" "repo hook says no" "$out"
expect "a hook failure is reported as a push failure" "git push failed" "$out"
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
refute "settings stay out of git status" "shiprc|codereviewrc" "$(git status --porcelain)"
bash "$skill/scripts/set-ship-stage.sh" push > /dev/null 2>&1
assert "exclude lines aren't duplicated" "$(cat .git/info/exclude)" \
    [ "$(grep -cxF working/code-review-report.md .git/info/exclude)" = 1 ]

# --- .gitignore can't be committed: the line is added, the note says why ----------

echo "== uncommitted .gitignore"
new_repo dirtyignore
echo "*.log" > .gitignore
out=$(bash "$ship" --plan --stage push 2>&1)
expect "a .gitignore with local changes isn't committed" "didn't commit it, because it has uncommitted changes of yours" "$out"
expect "the line is still added" "^\.shiprc$" "$(cat .gitignore)"
expect "nothing was committed" "^Change app$" "$(git log -1 --format=%s)"
git checkout -q develop
rm -f .shiprc
rm -f .gitignore
out=$(bash "$ship" --plan --stage push 2>&1)
expect "on develop the .gitignore change isn't committed" "didn't commit it, because you're on develop" "$out"

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
expect "plan lists review_docs" "review_docs +auto" "$out"
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

# --- a scaffolded repo: the project's tooling and pre-push hook -------------------

echo "== scaffolded repo"
new_repo scaffolded .codereviewrc
if [ -f "$scaffold_common" ]; then
    mkdir -p scripts/lib
    cp "$scaffold_common" scripts/lib/common.sh
    git add scripts
    git commit -qm "Add review tooling"
    echo ship_stage=push >> .codereviewrc
    out=$(bash "$ship" --plan 2>&1)
    expect "a scaffolded repo gets a new .shiprc" "NOTE: created \.shiprc with the default ship settings" "$out"
    expect "ship keys come from .shiprc, not .codereviewrc" "ship_stage +open_pr +\.shiprc" "$out"
    expect "review keys stay in .codereviewrc" "review_agent +custom +\.codereviewrc" "$out"
    expect "a missing pre-push hook fails" "pre-push hook isn't installed" "$out"
    printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
    out=$(bash "$ship" --plan --stage push 2>&1)
    expect "plan names the project's hook" "review: the project's pre-push hook" "$out"
    expect "plan passes" "SHIP_PREFLIGHT=passed" "$out"
    out=$(bash "$ship" --yes --stage push 2>&1)
    expect "scaffolded ship passes" "shipped to push" "$out"
    refute "the skill's review doesn't run" "Code review PASSED" "$out"
    sed -i.bak 's/^ship_contract=.*/ship_contract=99/' scripts/lib/common.sh && rm scripts/lib/common.sh.bak
    out=$(bash "$ship" --plan --stage push 2>&1)
    expect "a ship_contract mismatch is refused" "ship_contract=99" "$out"
    sed -i.bak '/^ship_contract=/d' scripts/lib/common.sh && rm scripts/lib/common.sh.bak
    out=$(bash "$ship" --plan --stage push 2>&1)
    expect "a common.sh without ship_contract isn't ours" "review: the ship skill's code-review.sh" "$out"
else
    echo "SKIP  scaffolded repo checks ($scaffold_common not found)"
fi

echo ""
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
