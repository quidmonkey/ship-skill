#!/usr/bin/env bash
# Two-pass agentic code review. ship.sh runs it in the ship worktree before
# each push. It finds the project's documents itself (review_docs), and works
# with none.
#   Pass 1: general review — correctness, security, missing tests, DRY,
#           YAGNI, library leverage, fit with the codebase.
#   Pass 2: conformance to the project's documents and the decisions
#           recorded in commit trailers (scripts/decisions.sh).
# Every pass ranks its sources: documents > tests > code.
# The passes are independent and run in parallel.
#
# Commits are reviewed once: the last passing commit per branch is recorded in
# .git/code-review-ledger (shared by every worktree, written under a lock), and
# later pushes review only new commits since.
# The full report is written to $report (excluded from git).
#
# A failed review hands its REQUIRED findings (both passes combined) to a
# single fix agent that fixes or disputes each one, then a verification pass
# checks the fix, in a loop of up to fix_max_iterations rounds (0 turns the
# fix loop off). Fixes are left uncommitted; the push stays blocked either
# way — a passing working tree isn't a passing commit yet.
#
# Config: .shiprc (key=value) — review_model, review_effort,
#         fix_max_iterations, fix_checks, agent_timeout, review_docs. ship.sh
#         validates them in its plan and passes one-run overrides as
#         CR_<KEY>. The other agents' models are fixed in lib/common.sh.
# Base:   REVIEW_BASE_BRANCH, the ship's target, is a branch's first-review
#         base.
#
# If the fix loop below resolves every REQUIRED finding, this script still
# exits non-zero (see $autofix_marker in lib/common.sh); ship.sh commits that
# fix and runs it again, once.
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/review-docs.sh
source "$script_dir/lib/review-docs.sh"

report="working/code-review-report.md"

# Set explicitly rather than inheriting the CLI's default model. Aliases
# (opus, sonnet) still move to each new release; a full model ID pins exactly.
# Pass 1 hunts for bugs nobody has named yet, the hardest job in the gate, so
# it gets the strongest model and a higher effort; a missed bug is invisible,
# and a false REQUIRED costs a fix and a verification round.
review_model=$(rc_value review_model)
review_effort=$(rc_value review_effort)
# Every call gets an explicit effort: the CLI default moves between releases,
# and effort levels don't mean the same amount of thinking across models.
# Pass 2, fix verification and the fixer use the fixed review_spec_* and fix_*
# choices from lib/common.sh.
# Auto-fix rounds after a failed review; 0 turns the fix loop off.
fix_max_iterations=$(rc_value fix_max_iterations)
# The lint and test commands, ;-separated; empty when none apply. The fixer runs
# them to check its work, and the reviewers may run them to confirm a finding.
fix_checks=$(rc_value fix_checks)
# Seconds any one agent call may run before it's killed and counted as failed.
agent_timeout=$(rc_value agent_timeout)
# The files and directories that state the project's intended behavior,
# space-separated: auto (the default) looks in the usual places, none means
# the project has no such documents.
review_docs=$(rc_value review_docs)

# effort_flags_for <effort> sets $effort_flags: --effort <effort>, or nothing
# for "default", which leaves the CLI's own.
effort_flags_for() {
    effort_flags=()
    [ -n "${1:-}" ] && [ "$1" != default ] && effort_flags=(--effort "$1")
}

# run_review_agent <prompt> <model> <effort> prints the review to stdout; the
# review must end with "VERDICT: PASS" or "VERDICT: FAIL" as its final line.
# git status is allowed: the verification prompt needs it to see untracked files
# the fixer added, and a headless -p run has no prompt to approve it with.
# Both agents may also run the fix_checks commands (check_rules), so a review
# can confirm a behavior finding by running the tests instead of reasoning
# about it.
#
# Both agents are sandboxed the same way (claude_sandbox_flags):
#   --setting-sources user  keeps .claude/settings.json out: its Stop hooks would
#                           run pre-commit and the docs gate inside every pass,
#                           and its auto mode + allow rules would widen the tools.
#   --tools                 limits which built-in tools exist at all;
#                           --allowed-tools only pre-approves.
#   --permission-mode dontAsk  denies anything --allowed-tools doesn't cover.
# The prompt is an argument, so stdin is closed: otherwise -p waits on it.
claude_sandbox_flags=(--setting-sources user --permission-mode dontAsk)
git_rules="Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)"

# check_rules prints a ,Bash(<command>:*) allow rule for each fix_checks command.
check_rules() {
    local check
    while IFS= read -r check; do
        [ -n "$check" ] && printf ',Bash(%s:*)' "$check"
    done <<< "$(fix_check_list)"
}

run_review_agent() {
    local effort_flags
    effort_flags_for "$3"
    # ${a[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
    with_timeout "$agent_timeout" claude -p "$1" --model "$2" ${effort_flags[@]+"${effort_flags[@]}"} "${claude_sandbox_flags[@]}" \
        --tools "Read,Grep,Glob,Bash" \
        --allowed-tools "Read,Grep,Glob,$git_rules$(check_rules)" < /dev/null
}

# run_fix_agent reads the fix prompt as $1 and edits the working tree in place.
# Unlike the review agent it gets write tools.
run_fix_agent() {
    local effort_flags
    effort_flags_for "$fix_effort"
    with_timeout "$agent_timeout" claude -p "$1" --model "$fix_model" ${effort_flags[@]+"${effort_flags[@]}"} "${claude_sandbox_flags[@]}" \
        --tools "Read,Edit,Write,Grep,Glob,Bash" \
        --allowed-tools "Read,Edit,Write,Grep,Glob,$git_rules$(check_rules)" < /dev/null
}

# fix_check_list — fix_checks, one trimmed command per line; none lists nothing.
fix_check_list() {
    printf '%s\n' "$fix_checks" | tr ';' '\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -vx -e '' -e none
}

# --- diff range --------------------------------------------------------------

# Empty-tree hash: diff base for a brand-new repository's first push.
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# Pin HEAD once up front: the passes run minutes apart, and a commit made
# mid-review must never be recorded as reviewed.
head_sha=$(git rev-parse HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
base_branch=${REVIEW_BASE_BRANCH:-develop}

last_reviewed=$(ledger_get "$branch")

if [ -n "$last_reviewed" ] && git merge-base --is-ancestor "$last_reviewed" "$head_sha" 2>/dev/null; then
    # Reviewed before: only new commits since the last passing review.
    base=$last_reviewed
elif base=$(git merge-base "origin/$base_branch" "$head_sha" 2>/dev/null); then
    # First review of a branch: the whole branch vs the target.
    :
elif [ -z "$(git for-each-ref refs/remotes)" ]; then
    # Brand-new repository with no remote branches: everything is new.
    base=$empty_tree
else
    echo "ERROR: cannot determine a review base — origin/$base_branch not found." >&2
    exit 1
fi
range="$base..$head_sha"

# An error here must block, not skip: an unresolvable range looks identical to
# an empty diff on stdout, and silence would wave unreviewed commits through.
if ! changed=$(git diff --name-only "$range" 2>&1); then
    echo "ERROR: git diff $range failed — blocking push (cannot tell what is unreviewed):" >&2
    echo "$changed" >&2
    exit 1
fi
if [ -z "$changed" ]; then
    echo "No unreviewed changes in $range — skipping code review."
    exit 0
fi

# --- review passes -----------------------------------------------------------

# doc_sources: the documents that state intended behavior (lib/review-docs.sh).
review_doc_sources "$review_docs" "$head_sha"
[ -n "$doc_missing" ] && echo "WARNING: review_docs names paths that aren't in the commit, left out:$doc_missing" >&2
echo "Documents of intended behavior: $(review_docs_summary)"

mkdir -p working
# Cleared unconditionally so a stale marker from an earlier, unrelated blocked
# push can never be mistaken for this run's outcome — see common.sh.
rm -f "$autofix_marker"
{
    echo "# Code review report"
    echo
    echo "- Branch: \`$branch\`"
    echo "- Range: \`$range\`"
    echo "- Models: pass 1 \`$review_model\` (effort \`$review_effort\`), pass 2 and verification \`$review_spec_model\` (effort \`$review_spec_effort\`), fix \`$fix_model\` (effort \`$fix_effort\`)"
    echo "- Documents: $(review_docs_summary)"
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
} > "$report"

# finish_pass <title> <output-file> <agent-exit-status> — appends the pass
# output to the report. Returns 0 only if the agent exited 0 and the LAST
# NON-EMPTY line of the output is "VERDICT: PASS" — a verdict quoted or drafted
# mid-output must not count. Markdown emphasis and backticks are stripped first,
# so "**VERDICT: PASS**" counts; a verdict anywhere but the end does not.
finish_pass() {
    local title=$1 file=$2 status=$3 output
    output=$(cat "$file")
    {
        echo
        echo "## $title"
        echo
        echo "$output"
    } >> "$report"
    if [ "$status" -eq 124 ]; then
        echo "Agent timed out after ${agent_timeout}s (agent_timeout) during $title — see $report" >&2
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        echo "Agent failed (exit $status) during $title — see $report" >&2
        return 1
    fi
    printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '*`' |
        grep -q '^[[:space:]]*VERDICT: PASS[[:space:]]*$'
}

# show_pass <title> <output-file> <ok> — prints a pass's review so the results
# are readable in the terminal, pass or fail, not just in the report. Capped:
# a finding-heavy review can overflow stdout, and agent harnesses truncate
# long hook output — losing the verdict and "push blocked" lines printed
# after the passes. The full text is always in the report.
show_limit=100
show_pass() {
    local verdict=FAILED
    [ "$3" = 1 ] && verdict=PASSED
    echo ""
    echo "==== $1 — $verdict ===="
    head -n "$show_limit" "$2"
    if [ "$(wc -l < "$2")" -gt "$show_limit" ]; then
        echo "[... truncated at $show_limit lines — full pass output in $report]"
    fi
}

# The most recent review's or verification's open findings, and the fixer's
# latest summary. Stable files excluded from git rather than temp
# files: the agents read them, and a path inside the project needs no extra
# directory access in a headless run.
findings_file="working/code-review-findings.md"
fix_summary_file="working/code-review-fix-summary.md"

# --- documented intent ---------------------------------------------------------
# $authority tells every agent which documents state intended behavior and how
# they rank against tests and code.

if [ "${#doc_sources[@]}" -gt 0 ]; then
    doc_list=$(printf -- '- %s\n' "${doc_sources[@]}")
    read -r -d '' authority <<EOF || true
These documents state this project's intended behavior:
$doc_list

Source of truth, highest authority first: those documents > tests > code. The
documents state intended behavior; tests encode it where the documents are
silent; code only describes what happens now. Resolve a conflict by climbing to
the highest level that speaks to it. If CLAUDE.md sets a different order,
follow CLAUDE.md.
EOF
    read -r -d '' spec_scope <<'EOF' || true
Read the documents that bear on the change. Start with any design or
architecture overview among them (for example docs/design.md or
ARCHITECTURE.md). If they hold per-flow specs (for example docs/specs/), read
the ones covering the flows this change touches; each is the source of truth
for its own flow.

Check that the changed code conforms to the intent the documents lay out:
- Architecture and component boundaries match the documented design
- Behavior matches what the documents specify for the flows it touches
- Data flow and integration points match the documented design
- Nothing contradicts documented decisions or constraints
- A test changed in the range still matches the documents: a test rewritten to
  fit new behavior the documents don't call for lets the code overrule them
- If the change alters design, architecture, or public API that the documents
  describe, they were updated in the same change
EOF
else
    read -r -d '' authority <<EOF || true
This project has no documents stating its intended behavior ($no_docs_reason).
Source of truth, highest authority first: tests > code. Tests encode intended
behavior; code only describes what happens now. If CLAUDE.md sets a different
order, follow CLAUDE.md.
EOF
    read -r -d '' spec_scope <<'EOF' || true
There are no documents to check the code against, so check only the recorded
decisions below. Missing documentation is not a finding: don't ask for new
documents.
EOF
fi

# The REQUIRED bar for code findings, shared by pass 1 and the fix verification
# so a fix is judged by the same standard as the code it fixes.
read -r -d '' required_bar <<'EOF' || true
REQUIRED is limited to:
- a correctness bug
- a security vulnerability
- data loss or corruption
- a critical flow or core logic left untested, per CLAUDE.md

Every REQUIRED finding must state a concrete failure scenario: the input or
state, and the wrong result it produces (for a missing test, the untested flow
and what could regress unnoticed). A finding with no concrete scenario is
SUGGESTED.
EOF

# The fix_checks commands, one per indented line, for the prompts. The allow
# rules match a command only from its start, so a check run after cd or && is
# denied; checks_how says so in every prompt that lists them.
checks_block=$(fix_check_list | sed 's/^/    /')
checks_how="Run each one from the repository root as a command of its own, starting exactly as written here; one placed after cd, &&, ; or a pipe is denied."

# What every review-agent prompt says about running the code. The reviewers may
# run the fix_checks commands (check_rules); they share the worktree with each
# other and with the fixer's edits, so they must not change files.
if [ -n "$checks_block" ]; then
    read -r -d '' checks_rule <<EOF || true
You may run these lint and test commands to confirm a finding, adding arguments
where they help. Don't change any file: skip a command or option that rewrites
files. Note which findings you confirmed by running a command. $checks_how
$checks_block
EOF
else
    read -r -d '' checks_rule <<'EOF' || true
No lint or test commands are configured (fix_checks), so you can't run the
code. When a finding rests on behavior you couldn't run, say so.
EOF
fi

# Closing instruction for every review-agent prompt; finish_pass enforces it.
read -r -d '' verdict_rule <<'EOF' || true
End with your verdict, as plain text with no bold, backticks, or other
formatting. The very last line of your output must be exactly VERDICT: PASS if
there are no REQUIRED or OPEN findings, otherwise exactly VERDICT: FAIL. Write
nothing after it — no summary sentence, no closing remark. A verdict placed
anywhere but the last line, or wrapped in formatting, is read as FAIL and
blocks the push.
EOF

# run_review runs both passes over the committed range, prints and reports the
# outcome, and writes $findings_file.
#   $1 — the git range to review (e.g. "A..B")
# The passes are independent (each only reads the diff and repo files), so run
# them concurrently and append their report sections in order. Returns 0 only if
# both passes pass.
run_review() {
    local range=$1
    local p1 p2 o1 o2 s1 s2 ok1 ok2 pid1 pid2 decisions
    local paths=()

    # Inlined rather than left to the agent: it only has git log, and the
    # trailer query is easy to get subtly wrong.
    while IFS= read -r f; do
        [ -n "$f" ] && paths+=("$f")
    done <<< "$(git diff --name-only "$range")"
    decisions=$(bash "$script_dir/decisions.sh" --limit 40 -- ${paths[@]+"${paths[@]}"})
    [ -n "$decisions" ] || decisions="None recorded."

    # read -d '' (not $(cat <<EOF)): bash 3.2 mis-parses quotes inside heredocs
    # nested in command substitutions.
    read -r -d '' p1 <<EOF || true
You are performing pass 1 of 2 of a pre-push code review for this repository.

Scope: the changes in git range $range. Start with:
    git diff $range
Read surrounding source files as needed for context, and read CLAUDE.md, if
there is one, for this project's coding and testing guidelines.

$authority

$checks_rule

Review the changes for, in priority order:
- Correctness: logic errors, wrong conditions or boundaries, unhandled None or
  empty inputs, broken error handling, race conditions, callers the change breaks,
  and tests weakened, skipped, or deleted to make changed code pass
- Security (injection, secrets in code, unsafe deserialization, path traversal, etc.)
- Missing tests: gaps per the testing guidance in CLAUDE.md (critical flows and core logic need tests; handlers and unexpected paths do not)
- DRY: duplicated logic that should be extracted or should reuse an existing function
- YAGNI: speculative abstractions, unused flexibility, code with no current need
- Library leverage: hand-rolled code where the stdlib or an already-installed dependency does the job
- Whether the change makes sense in the context of the codebase

Style and formatting are out of scope: the project's linters gate them.

Report every finding as a markdown bullet:
- **REQUIRED** or **SUGGESTED** — \`file:line\` — what is wrong, the failure scenario (REQUIRED only), and what change is needed

$required_bar
DRY, YAGNI, library-leverage, and fit findings are SUGGESTED unless they also
cause one of the failures above.
If there are no findings, say so.

$verdict_rule
EOF

    read -r -d '' p2 <<EOF || true
You are performing pass 2 of 2 of a pre-push code review for this repository:
conformance to documented intent.

Scope: the changes in git range $range. Start with:
    git diff $range

$authority

$checks_rule

$spec_scope
- Nothing reverses a recorded decision below, or brings back an alternative it
  rejected, unless a commit in $range records a new Decision trailer that
  supersedes it

Decisions recorded in commit trailers on the changed paths, newest first.
Entries from commits inside $range are this change's own. When a recorded
decision and the documents disagree, the documents win.

$decisions

Where the documents are silent on an area, that is not a finding. Only
deviations from documented intent count.

Report every finding as a markdown bullet:
- **REQUIRED** or **SUGGESTED** — \`file:line\` (or doc section) — the spec statement, the deviation, and what change is needed

REQUIRED is limited to code that directly contradicts a documented statement,
code that reverses a recorded decision with no superseding Decision trailer in
the range, or a design, architecture, or public API change that leaves a
statement in the documents wrong. A change the documents don't describe needs
no doc update. Quote the statement or the trailer and its commit. Anything weaker, or resting on your reading of intent
rather than on what the doc says, is SUGGESTED.
If there are no findings, say so.

$verdict_rule
EOF

    o1=$(mktemp)
    o2=$(mktemp)
    echo ""
    echo "Running pass 1 (general review) and pass 2 (spec conformance) in parallel"
    echo "(this can take a few minutes)..."
    run_review_agent "$p1" "$review_model" "$review_effort" > "$o1" 2>&1 &
    pid1=$!
    run_review_agent "$p2" "$review_spec_model" "$review_spec_effort" > "$o2" 2>&1 &
    pid2=$!

    s1=0
    wait "$pid1" || s1=$?
    s2=0
    wait "$pid2" || s2=$?

    ok1=0
    ok2=0
    finish_pass "Pass 1: general review" "$o1" "$s1" && ok1=1
    finish_pass "Pass 2: spec conformance" "$o2" "$s2" && ok2=1
    show_pass "Pass 1: general review" "$o1" "$ok1"
    show_pass "Pass 2: spec conformance" "$o2" "$ok2"

    { cat "$o1"; echo; cat "$o2"; } > "$findings_file"
    rm -f "$o1" "$o2"
    [ "$ok1" = 1 ] && [ "$ok2" = 1 ]
}

# apply_fixes hands the open findings in $findings_file to a single fix agent
# (both passes combined — coupled fixes and shared root causes need one
# coherent pass, not one agent per finding). The agent fixes each finding or
# disputes it with evidence, edits the working tree, and leaves the changes
# uncommitted. Its summary goes to $fix_summary_file for the verifier, is
# appended to the report, and is printed to the terminal, capped like the
# review passes so it can't overflow and get truncated. $1 is a label suffix for
# the section/console line. Returns non-zero if the fixer could not run, so the
# loop can stop.
apply_fixes() {
    local label=$1 fix_prompt status=0 verify_rule
    if [ -n "$checks_block" ]; then
        verify_rule="- Verify before finishing: run each of these, adding arguments where they
  help (for example --files <changed files>). A fix that breaks them is not a fix.
  $checks_how
$checks_block"
    else
        verify_rule="- No lint or test commands are configured (fix_checks), so you can't run
  them. Say so in the summary."
    fi

    read -r -d '' fix_prompt <<EOF || true
You are the fix pass of a pre-push code review for this repository.

A code review of these changes failed. Read the findings in:
    $findings_file
and read CLAUDE.md, if there is one, for this project's coding and testing
guidelines.

$authority

Handle every finding marked REQUIRED or OPEN. Ignore SUGGESTED, RESOLVED, and
DISPUTE ACCEPTED findings.

Check each finding against the code before acting on it. Then either:
- fix it, or
- dispute it, when it is wrong: its failure scenario can't happen, or the
  behavior it flags is what the highest source that speaks to it specifies.
  A dispute needs evidence another reviewer can check: a file:line, a quoted
  doc statement, or test output.
  Change no code for a disputed finding. Don't dispute a finding just because
  the fix is hard.

Rules:
- Fix at the root cause. If several findings share one root cause, fix it once.
- Make the minimal, localized change that resolves each finding.
- When a test fails, fix the code, not the test, unless a higher source shows
  the test is wrong; then quote that statement in the summary. Never weaken,
  skip, or delete a test only to make a check pass.
- Edit files in the working tree. Do NOT stage, commit, amend, or push — leave
  all changes uncommitted for human review.
$verify_rule
- If a finding is valid but cannot be fixed safely and automatically, leave it
  and say why.

End with a report titled "Fix summary" with one entry per finding you handled,
each starting with FIXED, DISPUTED, or UNFIXED: the finding (file:line and what
was wrong), then exactly what you changed, the evidence for the dispute, or why
it could not be fixed. Keep it concise.
EOF

    echo ""
    echo "Applying fixes for REQUIRED findings$label"
    echo "(this can take a few minutes)..."
    run_fix_agent "$fix_prompt" > "$fix_summary_file" 2>&1 || status=$?
    # Carry on to verification either way: it judges whatever the fixer left.
    [ "$status" -eq 124 ] && echo "WARNING: fix agent timed out after ${agent_timeout}s (agent_timeout)." >&2

    {
        echo
        echo "## Auto-fix$label"
        echo
        cat "$fix_summary_file"
    } >> "$report"

    echo ""
    echo "==== Auto-fix$label — REQUIRED findings ===="
    head -n "$show_limit" "$fix_summary_file"
    if [ "$(wc -l < "$fix_summary_file")" -gt "$show_limit" ]; then
        echo "[... truncated at $show_limit lines — full fix summary in $report]"
    fi
}

# verify_fixes checks the fix pass instead of re-reviewing the whole branch: a
# fresh full review turns up new findings each round and may never converge.
# It judges each open finding RESOLVED, DISPUTE ACCEPTED, or OPEN, and reviews
# only the fix diff for new REQUIRED issues. It replaces $findings_file with
# what is still open, which is what the next fix pass reads. The committed fix
# still gets a full review on the next push. $1 is a label suffix. Returns 0
# only if nothing is left open.
verify_fixes() {
    local label=$1 prompt out status=0 ok=0

    read -r -d '' prompt <<EOF || true
You are verifying the fix pass of a pre-push code review for this repository.

A review found REQUIRED issues, and a fix agent has since edited the working
tree. Read:
    $findings_file — the findings to judge (REQUIRED or OPEN ones)
    $fix_summary_file — the fix agent's summary: FIXED, DISPUTED, or UNFIXED per finding
The fixes are uncommitted. See them with:
    git diff HEAD
    git status --porcelain
and read any new untracked files; they are part of the fix. Read surrounding
source, CLAUDE.md, and the documents named below as needed.

$authority

$checks_rule

Judge each REQUIRED or OPEN finding from the findings file:
- RESOLVED: the fix removes the failure scenario, or makes the code match the doc.
- DISPUTE ACCEPTED: the fix agent disputed it, and its evidence holds up when
  you check it yourself. The finding was wrong.
- OPEN: not fixed, fixed incompletely, disputed without evidence that holds up,
  or "fixed" by changing a test that no higher source shows was wrong.

Then review the fix diff (git diff HEAD plus new untracked files, not the rest
of the branch) for problems the fix itself introduces. $required_bar

Report as markdown bullets:
- **RESOLVED**, **DISPUTE ACCEPTED**, or **OPEN** — \`file:line\` — the original finding and your judgment
- **REQUIRED** — \`file:line\` — a new issue in the fix diff, its failure scenario, and the change needed

Restate each OPEN finding in full, with its failure scenario and the change
needed: the next fix pass reads only this report.

$verdict_rule
EOF

    out=$(mktemp)
    echo ""
    echo "Verifying the fixes$label (this can take a few minutes)..."
    run_review_agent "$prompt" "$review_spec_model" "$review_spec_effort" > "$out" 2>&1 || status=$?
    finish_pass "Fix verification$label" "$out" "$status" && ok=1
    show_pass "Fix verification$label" "$out" "$ok"
    mv "$out" "$findings_file"
    [ "$ok" = 1 ]
}

# --- initial review ----------------------------------------------------------
# Reviews the committed range that is actually being pushed. A pass here is the
# only outcome that records the ledger and lets the push through.

if run_review "$range"; then
    if ! ledger_set "$branch" "$head_sha"; then
        echo "Code review PASSED, but the ledger write failed — the next push reviews these commits again." >&2
    fi
    echo ""
    echo "Code review PASSED. Recorded for '$branch' — only new commits will be reviewed next push."
    echo "Report: $report"
    exit 0
fi

echo ""
echo "Code review FAILED — push blocked."
echo "Full report: $report"

if [ "$fix_max_iterations" -eq 0 ]; then
    echo "Fix the REQUIRED findings, commit, and push again."
    exit 1
fi

# --- fix / verify loop -------------------------------------------------------
# Fixes are uncommitted, so a verified fix is never recorded in the ledger (the
# passing state isn't a commit) and never lets this push through: the fixes
# must be committed and pushed, where they get one honest full review.

iteration=1
while :; do
    if ! apply_fixes " (iteration $iteration)"; then
        echo "Auto-fix could not run — push blocked. Fix the REQUIRED findings manually."
        exit 1
    fi

    if verify_fixes " (iteration $iteration)"; then
        echo ""
        if [ -z "$(git status --porcelain)" ]; then
            # Nothing to commit: every finding was disputed and the dispute
            # upheld. Getting past the gate from here is a human decision.
            echo "Every REQUIRED finding was disputed and the verifier accepted the disputes;"
            echo "no code changed, so this push is still blocked. Read $report and decide"
            echo "whether to ship again for a fresh review."
            exit 1
        fi
        echo "Auto-fix cleared all REQUIRED findings after $iteration iteration(s)."
        echo "The fixes are in the working tree, uncommitted — this push is still blocked."
        echo "The ship commits the fix and pushes again on its own."
        echo "Report: $report"
        touch "$autofix_marker"
        exit 1
    fi

    if [ "$iteration" -ge "$fix_max_iterations" ]; then
        echo ""
        echo "Auto-fix stopped after $iteration iteration(s) (fix_max_iterations=$fix_max_iterations) with findings still open."
        echo "Review the working tree and $report, finish the fixes, commit, and push again."
        exit 1
    fi

    iteration=$((iteration + 1))
done
