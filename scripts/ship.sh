#!/usr/bin/env bash
# Ship the current branch: push it (running the pre-push review gate), open a
# PR against the default branch, self-approve and enable auto-merge, then once
# it merges, check out the default branch, pull, and delete the branch.
#
# This is deliberately not part of scripts/code-review.sh's pre-push hook: that
# hook runs *before* the commits reach the remote, so a PR can't be opened
# against them yet. Everything here runs only after `git push` has actually
# succeeded — a REQUIRED review finding blocks `git push` exactly as it does
# today, and nothing PR-related runs until that gate is clear.
#
# Config: .codereviewrc (key=value) — pr_automation, pr_host, pr_merge_method,
#         pr_self_approve, pr_poll_interval, pr_poll_timeout, ship_fix_retries.
#
# pr_automation is off by default — a fresh clone has no .codereviewrc, and a
# push should never silently start opening and merging PRs. Turn it on with
# `make auto-pr`, or by answering yes to the prompt `make setup` runs once.
#
# ship_fix_retries: if code-review.sh's fix loop (fix_enabled=true, the
# default) resolves every REQUIRED finding, the fix is left uncommitted — the
# hook itself never commits or pushes on its own (see $autofix_marker in
# lib/common.sh). This script offers, with one confirmation, to commit that
# fix and push again, up to ship_fix_retries times.
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

pr_automation=$(rc_get pr_automation)
pr_automation=${pr_automation:-false}
ship_fix_retries=$(rc_get ship_fix_retries)
ship_fix_retries=${ship_fix_retries:-1}
case "$ship_fix_retries" in
    '' | *[!0-9]*)
        echo "ERROR: ship_fix_retries must be a non-negative integer in .codereviewrc — stopping." >&2
        exit 1
        ;;
esac

branch=$(git rev-parse --abbrev-ref HEAD)
base=$(default_branch)

if [ "$branch" = "$base" ]; then
    echo "ERROR: on the default branch ($base) — nothing to ship." >&2
    exit 1
fi

attempt=0
while :; do
    # Cleared before every attempt: only a marker written by *this* push's
    # hook run should be trusted as evidence of what just happened.
    rm -f "$autofix_marker"
    if [ "$attempt" -eq 0 ]; then
        echo "Pushing $branch (runs the code review gate — can take a few minutes)..."
    else
        echo "Pushing $branch again (attempt $((attempt + 1)))..."
    fi

    if git push -u origin "$branch"; then
        break
    fi

    if [ ! -f "$autofix_marker" ] || [ "$attempt" -ge "$ship_fix_retries" ]; then
        echo "ERROR: push failed, or was blocked by the code review gate — nothing shipped." >&2
        exit 1
    fi

    echo ""
    echo "Code review's auto-fix resolved every REQUIRED finding; the fixes below are"
    echo "uncommitted in your working tree:"
    echo ""
    git status --porcelain
    echo ""
    git --no-pager diff
    echo ""
    if [ -t 0 ]; then
        printf 'Commit these fixes and push again? [y/N] '
        read -r reply
    else
        reply=n
        echo "Not an interactive shell — treating that as no."
    fi
    case "$reply" in
        [yY]*) ;;
        *)
            echo "Leaving the fixes uncommitted. Review the diff, commit, and run 'make ship' again."
            exit 1
            ;;
    esac

    git add -A
    if ! git commit -q -m "Apply code review auto-fix" \
        -m "Auto-fix resolved the REQUIRED findings from the pre-push code review." \
        -m "See working/code-review-report.md (local, gitignored) for what was found and fixed."; then
        echo "ERROR: nothing to commit — the fix may have been a no-op. Check the working tree." >&2
        exit 1
    fi
    attempt=$((attempt + 1))
done

if [ "$pr_automation" != "true" ]; then
    echo "Auto-PR is off (pr_automation != true) — pushed only, open the PR yourself. Run 'make auto-pr' to enable it."
    exit 0
fi

pr_host=$(rc_get pr_host)
if [ -z "$pr_host" ]; then
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    case "$origin_url" in
        *github.com*) pr_host=gh ;;
        *) pr_host=az ;;
    esac
fi

case "$pr_host" in
    gh) command -v gh >/dev/null 2>&1 || { echo "ERROR: pr_host=gh but the gh CLI is not installed." >&2; exit 1; } ;;
    az) command -v az >/dev/null 2>&1 || { echo "ERROR: pr_host=az but the az CLI is not installed." >&2; exit 1; } ;;
    *) echo "ERROR: unknown pr_host '$pr_host' in .codereviewrc (gh | az)." >&2; exit 1 ;;
esac

pr_merge_method=$(rc_get pr_merge_method)
pr_merge_method=${pr_merge_method:-squash}
pr_self_approve=$(rc_get pr_self_approve)
pr_self_approve=${pr_self_approve:-true}
pr_poll_interval=$(rc_get pr_poll_interval)
pr_poll_interval=${pr_poll_interval:-15}
pr_poll_timeout=$(rc_get pr_poll_timeout)
pr_poll_timeout=${pr_poll_timeout:-1800}

# --- PR description from the branch's commits ---------------------------------
# First commit subject (oldest first) is the title; the full log (oldest
# first, subject + body) is the description. No agent needed: the commits
# already say what changed.
title=$(git log "$base..$branch" --reverse --format='%s' | head -n 1)
title=${title:-$branch}
body=$(git log "$base..$branch" --reverse --format='- %s%n%n%b')

echo ""
echo "Opening PR: $branch -> $base"

# --- host-specific create / approve / auto-merge -------------------------------

case "$pr_host" in
gh)
    pr_url=$(gh pr create --base "$base" --head "$branch" --title "$title" --body "$body") || {
        echo "ERROR: gh pr create failed." >&2
        exit 1
    }
    echo "$pr_url"

    if [ "$pr_self_approve" = "true" ]; then
        gh pr review "$pr_url" --approve 2>&1 \
            || echo "NOTE: self-approve rejected (branch protection?) — auto-merge will wait for a human review instead." >&2
    fi

    merge_flag="--squash"
    [ "$pr_merge_method" = "merge" ] && merge_flag="--merge"
    [ "$pr_merge_method" = "rebase" ] && merge_flag="--rebase"

    if ! gh pr merge "$pr_url" --auto "$merge_flag" --delete-branch; then
        echo "ERROR: could not enable auto-merge on $pr_url — it's open, ship it manually." >&2
        exit 1
    fi

    echo "Auto-merge armed — polling every ${pr_poll_interval}s, up to ${pr_poll_timeout}s..."
    elapsed=0
    state=OPEN
    while [ "$elapsed" -lt "$pr_poll_timeout" ]; do
        state=$(gh pr view "$pr_url" --json state --jq .state 2>/dev/null)
        [ "$state" = "MERGED" ] && break
        if [ "$state" = "CLOSED" ]; then
            echo "ERROR: $pr_url was closed without merging." >&2
            exit 1
        fi
        sleep "$pr_poll_interval"
        elapsed=$((elapsed + pr_poll_interval))
    done
    if [ "$state" != "MERGED" ]; then
        echo "Still not merged after ${pr_poll_timeout}s — auto-merge stays armed. Check $pr_url." >&2
        exit 1
    fi
    ;;
az)
    # Requires the azure-devops extension and defaults set once per machine:
    #   az extension add --name azure-devops
    #   az devops configure --defaults organization=<org-url> project=<project>
    pr_id=$(az repos pr create --source-branch "$branch" --target-branch "$base" \
        --title "$title" --description "$body" --query pullRequestId -o tsv) || {
        echo "ERROR: az repos pr create failed." >&2
        exit 1
    }
    echo "PR $pr_id"

    if [ "$pr_self_approve" = "true" ]; then
        az repos pr set-vote --id "$pr_id" --vote approve 2>&1 \
            || echo "NOTE: self-approve rejected (branch protection?) — auto-complete will wait for a human review instead." >&2
    fi

    squash=true
    [ "$pr_merge_method" != "squash" ] && squash=false

    if ! az repos pr update --id "$pr_id" --auto-complete true --squash "$squash" --delete-source-branch true; then
        echo "ERROR: could not enable auto-complete on PR $pr_id — it's open, complete it manually." >&2
        exit 1
    fi

    echo "Auto-complete armed — polling every ${pr_poll_interval}s, up to ${pr_poll_timeout}s..."
    elapsed=0
    status=active
    while [ "$elapsed" -lt "$pr_poll_timeout" ]; do
        status=$(az repos pr show --id "$pr_id" --query status -o tsv 2>/dev/null)
        [ "$status" = "completed" ] && break
        if [ "$status" = "abandoned" ]; then
            echo "ERROR: PR $pr_id was abandoned without merging." >&2
            exit 1
        fi
        sleep "$pr_poll_interval"
        elapsed=$((elapsed + pr_poll_interval))
    done
    if [ "$status" != "completed" ]; then
        echo "Still not completed after ${pr_poll_timeout}s — auto-complete stays armed. Check PR $pr_id." >&2
        exit 1
    fi
    ;;
esac

# --- land it --------------------------------------------------------------------
# The host may already have deleted the local branch (gh --delete-branch does,
# when it was checked out); `-d` failing because it's already gone is fine.

echo ""
echo "Merged. Checking out $base, pulling, and cleaning up $branch..."
git checkout "$base"
git pull
git branch -d "$branch" 2>/dev/null || true
echo "Done — $branch is merged into $base and removed locally."
