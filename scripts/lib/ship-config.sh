# shellcheck shell=bash
# Loads the project's shared helpers and adds the ship settings to them.
# Sourced by ship.sh and set-ship-stage.sh, not executed.
#
# The project's scripts/lib/common.sh (written by the scaffold skill) is the
# contract between this skill and the repo: rc_* (config), ledger_* (review
# ledger), with_timeout and autofix_marker. Its ship_contract names the version;
# a project with a different one is refused rather than half-working.

# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

ship_contract_required=1

project_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: not inside a git repository." >&2
    exit 1
}
project_scripts="$project_root/scripts"
if [ ! -f "$project_scripts/lib/common.sh" ]; then
    echo "ERROR: $project_scripts/lib/common.sh is missing. /ship needs the review tooling the scaffold skill writes; see the ship skill's README.md." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$project_scripts/lib/common.sh"
if [ "${ship_contract:-}" != "$ship_contract_required" ]; then
    echo "ERROR: this project's scripts/lib/common.sh has ship_contract=${ship_contract:-(none)}, and the ship skill needs $ship_contract_required." >&2
    echo "Update whichever is older: git -C ~/.claude/skills/ship pull, or the project's scripts/ from the scaffold skill's templates." >&2
    exit 1
fi

# The branch ship.sh opens PRs into and merges into by default (--target
# changes it), and the branch a prod ship (--target main or master) releases.
ship_base=develop

rc_known_keys="$rc_known_keys ship_stage ship_fix_retries ship_log_retention_days
ship_notify pr_host pr_merge_method pr_self_approve pr_poll_interval
pr_poll_timeout pr_reviewers deploy_pipeline deploy_provider deploy_project
deploy_region deploy_name deploy_match deploy_proxy deploy_smoke
deploy_run_grace deploy_poll_timeout deploy_smoke_timeout"

# rc_default_extra <key> — the built-in default for a ship key. The project's
# rc_default calls it for any key it doesn't know.
rc_default_extra() {
    case "$1" in
        ship_stage) echo open_pr ;;
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
