#!/usr/bin/env bash
# Write ship_stage into .codereviewrc: how far /ship and `make ship` go after
# the review and push. Stages are cumulative:
#   push           stop after the push
#   open_pr        open a PR into develop (the default)
#   merge          also self-approve, arm auto-merge, and wait for the merge
#   verify_deploy  also wait for the dev deploy, check health, run the smoke test
#
# Usage:
#   scripts/set-ship-stage.sh <stage>    # make ship-stage STAGE=<stage>
#   scripts/set-ship-stage.sh --prompt   # ask, default open_pr; no-op without a TTY (make setup)
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

stages="push open_pr merge verify_deploy"

set_stage() {
    if ! in_list "$1" "$stages"; then
        echo "ERROR: unknown stage '$1' (push | open_pr | merge | verify_deploy)." >&2
        exit 1
    fi
    rc_set ship_stage "$1"
    echo "ship_stage=$1 written to .codereviewrc. Override it for one run with /ship <stage> or make ship STAGE=<stage>."
    case "$1" in
        open_pr | merge) echo "Needs the gh (or az) CLI, logged in with permission to open and merge PRs." ;;
        verify_deploy) echo "Needs gh/az and gcloud, plus the deploy_* settings in .codereviewrc." ;;
    esac
}

case "${1:-}" in
    --prompt)
        if [ ! -t 0 ]; then
            echo "Skipping the ship stage prompt (no TTY); /ship goes as far as $(rc_value ship_stage). Run 'make ship-stage STAGE=<stage>' to change it."
            exit 0
        fi
        read -r -p "How far should /ship go after review and push? push | open_pr | merge | verify_deploy [open_pr] " answer
        set_stage "${answer:-open_pr}"
        ;;
    '')
        echo "ERROR: name a stage (push | open_pr | merge | verify_deploy), or --prompt." >&2
        exit 1
        ;;
    *) set_stage "$1" ;;
esac
