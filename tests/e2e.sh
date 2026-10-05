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
# mode, and "autofix" passes once the fix stub has run.
cat > "$sb/review.sh" <<EOF
prompt=\$(cat)
case "\$prompt" in *"verifying the fix pass"*) echo "- RESOLVED"; echo "VERDICT: PASS"; exit 0 ;; esac
mode=\$(cat "$sb/mode")
if [ "\$mode" = pass ] || { [ "\$mode" = autofix ] && grep -q fixed app.txt; }; then
    echo "No findings."; echo "VERDICT: PASS"
else
    echo "- **REQUIRED** — app.txt:1 — broken, fails on every input"; echo "VERDICT: FAIL"
fi
EOF
cat > "$sb/fix.sh" <<'EOF'
cat > /dev/null
echo fixed >> app.txt
echo "Fix summary"; echo "FIXED app.txt:1"
EOF

# new_repo <name> — a repo on feature/x, one commit ahead of origin/develop.
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
    cat > .codereviewrc <<EOF
review_agent=custom
command=sh $sb/review.sh
fix_agent=custom
fix_command=sh $sb/fix.sh
EOF
    echo pass > "$sb/mode"
}

# --- a plain repo: no Makefile, no scripts/, no hooks ---------------------------

echo "== plain repo"
new_repo plain

out=$(bash "$ship" --plan --stage push 2>&1)
expect "plan passes with no project tooling" "SHIP_PREFLIGHT=passed" "$out"
expect "plan names the skill's review" "review: the ship skill's code-review.sh" "$out"
expect "no ship_setup without pyproject.toml" "ship_setup +\(none\)" "$out"
refute "uv isn't required" "uv isn't on PATH" "$out"
expect "fix_checks is shown" "fix_checks" "$out"
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
assert "passing ship exits 0 (rc=$rc)" "$out" [ "$rc" -eq 0 ]
snap="ship/feature/x-${sha:0:7}"
assert "origin has $snap" "$(git ls-remote origin)" on_origin "$snap"
assert "passed ship removes its worktree" "$(git worktree list)" no_extra_worktrees
assert "checkout is still feature/x" "$(git status)" [ "$(git symbolic-ref --short HEAD)" = feature/x ]
assert "checkout is clean" "$(git status)" [ -z "$(git status --porcelain)" ]
excl=$(cat .git/info/exclude)
expect "working/ excluded locally" "^working$" "$excl"
expect ".codereviewrc excluded locally" "^\.codereviewrc$" "$excl"
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
expect "auto-fix ship passes" "shipped to push" "$out"
asnap=$(snapshot_of "$(latest)")
expect "origin tip is the auto-fix commit" "Apply code review auto-fix" "$(git log -1 --format=%s "origin/$asnap" 2>&1)"
files=$(git show --name-only --format= "origin/$asnap")
expect "auto-fix commit has the fix" "^app.txt$" "$files"
refute "auto-fix commit has no working/ or .codereviewrc" "working/|codereviewrc" "$files"
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
expect "set-ship-stage writes the stage" "ship_stage=merge written" "$out"
refute ".codereviewrc stays out of git status" "codereviewrc" "$(git status --porcelain)"
bash "$skill/scripts/set-ship-stage.sh" push > /dev/null 2>&1
assert "exclude lines aren't duplicated" "$(cat .git/info/exclude)" \
    [ "$(grep -cxF .codereviewrc .git/info/exclude)" = 1 ]

# --- a repo that tracks .codereviewrc: personal edits stay out of commits ---------

echo "== tracked .codereviewrc"
new_repo tracked
git add -f .codereviewrc
git commit -qm "Track review settings"
echo "# personal edit" >> .codereviewrc
echo autofix > "$sb/mode"
out=$(bash "$ship" --yes --stage push 2>&1)
expect "tracked-settings ship passes" "shipped to push" "$out"
files=$(git show --name-only --format= "origin/$(snapshot_of "$(latest)")")
expect "auto-fix commit has the fix" "^app.txt$" "$files"
refute "auto-fix commit leaves the tracked .codereviewrc out" "codereviewrc" "$files"
refute "a tracked .codereviewrc isn't excluded" "codereviewrc" "$(cat .git/info/exclude)"

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
new_repo scaffolded
if [ -f "$scaffold_common" ]; then
    mkdir -p scripts/lib
    cp "$scaffold_common" scripts/lib/common.sh
    git add scripts
    git commit -qm "Add review tooling"
    out=$(bash "$ship" --plan --stage push 2>&1)
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
