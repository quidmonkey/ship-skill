# shellcheck shell=bash
# Loads the shared helpers and the ship's settings file. Sourced by ship.sh
# and set-ship-stage.sh, not executed.

# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

skill_scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
project_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: not inside a git repository." >&2
    exit 1
}
# shellcheck source=common.sh
source "$skill_scripts/lib/common.sh"
# shellcheck source=review-docs.sh
source "$skill_scripts/lib/review-docs.sh"
# shellcheck source=toolchain.sh
source "$skill_scripts/lib/toolchain.sh"
review_sh="$skill_scripts/code-review.sh"
decisions_sh="$skill_scripts/decisions.sh"

# The ship's personal settings. ship_rc_init creates the file and keeps it
# out of git through .git/info/exclude.
ship_rc=.shiprc

# ship_local_paths — paths a ship writes that must never be committed: the
# review's reports and personal settings. Files rather than all of working/,
# so a repo that tracks its own working/ keeps committing it.
ship_local_paths="working/code-review-report.md working/code-review-findings.md
working/code-review-fix-summary.md $autofix_marker $ship_rc"

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

# Fixed ship behavior. One auto-fix retry is enough: the fix loop has already
# converged the fix, so a second is only needed if the fresh commit's full
# review turns up something new.
ship_fix_retries=1
pr_poll_interval=15
ship_log_retention_days=30

# ship_rc_init — creates .shiprc from shiprc.template when it's missing, with
# a NOTE: line for /ship to relay, then excludes it and the review's files
# from git (ship_exclude_local). Nothing is committed.
ship_rc_init() {
    if [ ! -f "$ship_rc" ]; then
        cp "$skill_scripts/../shiprc.template" "$ship_rc"
        echo "NOTE: created $ship_rc with the default ship settings, kept out of git by .git/info/exclude. Edit it to change them."
    fi
    ship_exclude_local
}
