# shellcheck shell=bash
# Loads the shared helpers and adds the ship settings to them. Sourced by
# ship.sh and set-ship-stage.sh, not executed.
#
# The review tooling comes from one of two places:
#   project  the repo has the scaffold skill's scripts/lib/common.sh (it sets
#            ship_contract). Its pre-push hook reviews each push, and ship.sh
#            sources its common.sh: rc_* (config), ledger_* (review ledger),
#            with_timeout and autofix_marker. A ship_contract other than the
#            one below is refused rather than half-working.
#   skill    any other repo. ship.sh sources this skill's lib/common.sh and
#            runs this skill's code-review.sh in the worktree before each push.

# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

ship_contract_required=1

skill_scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
project_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: not inside a git repository." >&2
    exit 1
}
project_common="$project_root/scripts/lib/common.sh"
if [ -f "$project_common" ] && grep -q '^ship_contract=' "$project_common"; then
    review_tooling=project
    # shellcheck source=/dev/null
    source "$project_common"
    if [ "$ship_contract" != "$ship_contract_required" ]; then
        echo "ERROR: this project's scripts/lib/common.sh has ship_contract=$ship_contract, and the ship skill needs $ship_contract_required." >&2
        echo "Update whichever is older: git -C ~/.claude/skills/ship pull, or the project's scripts/ from the scaffold skill's templates." >&2
        exit 1
    fi
else
    review_tooling=skill
    # shellcheck source=common.sh
    source "$skill_scripts/lib/common.sh"
fi
review_sh="$skill_scripts/code-review.sh"
decisions_sh="$project_root/scripts/decisions.sh"
[ -f "$decisions_sh" ] || decisions_sh="$skill_scripts/decisions.sh"

# ship_local_paths — paths a ship writes that must never be committed: the
# review's reports and personal settings.
ship_local_paths="working .codereviewrc"

# ship_exclude_local — adds each of ship_local_paths to the repo's local
# excludes (.git/info/exclude, never committed) unless it's already ignored,
# already listed, or tracked (an exclude can't hide a tracked file; the
# auto-fix commit leaves those out by pathspec instead).
ship_exclude_local() {
    local exclude p
    exclude="$(git rev-parse --git-common-dir)/info/exclude"
    for p in $ship_local_paths; do
        git check-ignore -q "$p" && continue
        [ -n "$(git ls-files -- "$p")" ] && continue
        grep -qxF "$p" "$exclude" 2>/dev/null && continue
        mkdir -p "$(dirname "$exclude")"
        printf '%s\n' "$p" >> "$exclude"
    done
}

# The branch ship.sh opens PRs into and merges into by default (--target
# changes it), and the branch a prod ship (--target main or master) releases.
ship_base=develop

rc_known_keys="$rc_known_keys ship_stage ship_setup ship_fix_retries ship_log_retention_days
ship_notify pr_host pr_merge_method pr_self_approve pr_poll_interval
pr_poll_timeout pr_reviewers deploy_pipeline deploy_provider deploy_project
deploy_region deploy_name deploy_match deploy_proxy deploy_smoke
deploy_run_grace deploy_poll_timeout deploy_smoke_timeout"

# rc_default_extra <key> — the built-in default for a ship key. The project's
# rc_default calls it for any key it doesn't know.
rc_default_extra() {
    case "$1" in
        ship_stage) echo open_pr ;;
        # Run in a new worktree before the push, so the review's fixer and the
        # repo's hooks have its dependencies.
        ship_setup) [ -f pyproject.toml ] && echo 'uv sync -q' ;;
        ship_fix_retries) echo 1 ;;
        ship_log_retention_days) echo 30 ;;
        ship_notify) echo none ;;
        pr_host)
            case "$(git remote get-url origin 2>/dev/null)" in
                *github.com*) echo gh ;;
                *) echo az ;;
            esac
            ;;
        pr_merge_method) echo squash ;;
        pr_self_approve) echo true ;;
        pr_poll_interval) echo 15 ;;
        pr_poll_timeout) echo 1800 ;;
        deploy_region) echo us-central1 ;;
        deploy_match) echo time ;;
        deploy_proxy) echo false ;;
        deploy_run_grace) echo 300 ;;
        deploy_poll_timeout) echo 3600 ;;
        deploy_smoke_timeout) echo 900 ;;
    esac
}
