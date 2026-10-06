#!/usr/bin/env bash
# Write ship_stage into .shiprc: how far /ship and `make ship` go after
# the review and push. Stages are cumulative:
#   push           stop after the push
#   open_pr        open a PR into develop (the default)
#   merge          also self-approve, arm auto-merge, and wait for the merge
#   verify_deploy  also run deploy_check against the deploy of the merge commit
#
# Usage:
#   set-ship-stage.sh <stage>    # make ship-stage STAGE=<stage>
# Run from the project root; it writes the project's .shiprc, creating it
# first if it's missing (see ship_rc_init).
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/ship-config.sh
source "$script_dir/lib/ship-config.sh"

stages="push open_pr merge verify_deploy"

if ! in_list "${1:-}" "$stages"; then
    echo "ERROR: name a stage: push | open_pr | merge | verify_deploy." >&2
    exit 1
fi
ship_rc_init
rc_set ship_stage "$1" "$ship_rc"
echo "ship_stage=$1 written to $ship_rc. Override it for one run with /ship <stage> or make ship STAGE=<stage>."
case "$1" in
    open_pr | merge) echo "Needs the gh (or az) CLI, logged in with permission to open and merge PRs." ;;
    verify_deploy) echo "Needs gh/az, plus deploy_check in $ship_rc." ;;
esac
