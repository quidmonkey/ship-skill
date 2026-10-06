# shellcheck shell=bash
# Shared helpers for code-review.sh and ship.sh: settings (rc_*), the review
# ledger (ledger_*) and with_timeout. Sourced, not executed — no shebang, no
# set -u here (each caller sets its own options).

# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

# code-review.sh's fix/verify loop touches this file instead of just
# exiting when it resolves every REQUIRED finding — the fixes are still
# uncommitted (the fix loop never commits or pushes on its own), but ship.sh
# looks for this file right after a failed review to know whether it's
# looking at an unfixable failure or a fix sitting in the working tree ready
# to be committed. Excluded from git, like the report.
autofix_marker="working/autofix-pending.marker"

# Every key .shiprc understands. An override (--set or CR_<KEY>) naming
# anything else is a typo and fails, so it can't be silently ignored.
rc_known_keys="ship_stage pr_reviewers pr_host pr_merge_method pr_self_approve
pr_poll_timeout ship_setup fix_checks review_docs review_model review_effort
fix_max_iterations agent_timeout deploy_check deploy_timeout ship_notify"

# Fixed choices for the review's other agents. Pass 2 and fix verification
# compare code against a stated doc or finding, and the fixer works from
# findings that already name the file, the failure and the change needed, so
# neither needs pass 1's model. Not low effort: at low effort a fixer is more
# likely to report a fix done without running the checks that exercise it.
review_spec_model=sonnet
review_spec_effort=medium
fix_model=sonnet
fix_effort=medium

# rc_env_name <key> — the environment variable that overrides <key>: CR_ plus
# the key in uppercase. The prefix keeps the keys from colliding with
# unrelated variables.
rc_env_name() {
    printf 'CR_%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

# rc_get <key> [rc-file] — the raw value of <key>: the CR_<KEY> environment
# variable if it's set (even to empty, which means "use the default"),
# otherwise key=value from an rc file (default .shiprc), one per line.
# Strips inline comments (whitespace then #) and surrounding whitespace, so a
# line copied with its trailing comment parses. Prints the last matching line
# if a key repeats. Prints nothing for an unset key; see rc_value.
rc_get() {
    local key=$1 file=${2:-.shiprc} env_name
    env_name=$(rc_env_name "$key")
    if [ -n "${!env_name+x}" ]; then
        printf '%s\n' "${!env_name}"
        return
    fi
    sed -n "s/^$key=//p" "$file" 2>/dev/null | tail -n 1 \
        | sed -e 's/[[:space:]][[:space:]]*#.*$//' \
              -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# rc_default <key> — the built-in default, used when no override or rc line
# sets a value. An absent .shiprc behaves exactly like the template.
rc_default() {
    case "$1" in
        review_model) echo opus ;;
        review_effort) echo high ;;
        fix_max_iterations) echo 2 ;;
        agent_timeout) echo 900 ;;
        # Commands the fix agent runs to check its work, separated by ;. Each
        # one is also what the agent is allowed to run, with any arguments.
        fix_checks) [ -f pyproject.toml ] && echo 'uv run pre-commit;uv run pytest' ;;
        # The review finds the project's documents (lib/review-docs.sh).
        review_docs) echo auto ;;
        ship_stage) echo open_pr ;;
        # Run in a new worktree before the push, so the review's fixer and the
        # repo's hooks have its dependencies; none runs nothing. The first ship
        # usually sets it in .shiprc (lib/toolchain.sh), so this is the fallback.
        ship_setup) [ -f pyproject.toml ] && echo 'uv sync -q' ;;
        ship_notify) echo none ;;
        pr_host)
            case "$(git remote get-url origin 2>/dev/null)" in
                *github.com*) echo gh ;;
                *) echo az ;;
            esac
            ;;
        pr_merge_method) echo squash ;;
        pr_self_approve) echo true ;;
        pr_poll_timeout) echo 1800 ;;
        deploy_timeout) echo 3600 ;;
    esac
}

# rc_value <key> — rc_get, falling back to rc_default when empty.
rc_value() {
    local v
    v=$(rc_get "$1")
    if [ -n "$v" ]; then
        printf '%s\n' "$v"
    else
        rc_default "$1"
    fi
}

# in_list <word> <list> — true if <word> is one of the whitespace-separated
# words in <list>.
in_list() {
    local w
    for w in $2; do
        [ "$w" = "$1" ] && return 0
    done
    return 1
}

# rc_is_known <key> — true if <key> is in rc_known_keys.
rc_is_known() {
    in_list "$1" "$rc_known_keys"
}

# rc_closest_key <word> — the known key with the smallest edit distance to
# <word>, for "did you mean" messages.
rc_closest_key() {
    # shellcheck disable=SC2086 # word-splitting the key list is the point
    printf '%s\n' $rc_known_keys | awk -v w="$1" '
        function lev(a, b,   i, j, la, lb, d, c) {
            la = length(a); lb = length(b)
            for (i = 0; i <= la; i++) d[i, 0] = i
            for (j = 0; j <= lb; j++) d[0, j] = j
            for (i = 1; i <= la; i++)
                for (j = 1; j <= lb; j++) {
                    c = (substr(a, i, 1) != substr(b, j, 1))
                    d[i, j] = d[i-1, j] + 1
                    if (d[i, j-1] + 1 < d[i, j]) d[i, j] = d[i, j-1] + 1
                    if (d[i-1, j-1] + c < d[i, j]) d[i, j] = d[i-1, j-1] + c
                }
            return d[la, lb]
        }
        { s = lev(w, $0); if (best == "" || s < bestscore) { best = $0; bestscore = s } }
        END { print best }'
}

# rc_set <key> <value> [rc-file] — writes key=value into an rc file, replacing
# the existing line for that key if present or appending a new one otherwise.
# Creates the file (with a header comment) if it doesn't exist yet. Used to
# record a personal choice (e.g. ship_stage) without touching other keys.
rc_set() {
    local key=$1 value=$2 file=${3:-.shiprc}
    if [ ! -f "$file" ]; then
        printf '# Personal review/ship automation settings (kept out of git) -- see docs/reference.md in the ship skill.\n' > "$file"
    fi
    if grep -q "^$key=" "$file" 2>/dev/null; then
        sed -i.bak "s/^$key=.*/$key=$value/" "$file" && rm -f "$file.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# --- review ledger ---------------------------------------------------------------
# The last passing commit per branch, one "<branch> <sha>" line each. It lives in
# the common git dir so every worktree (ship.sh's included) shares it.

ledger_path() {
    printf '%s/code-review-ledger\n' "$(git rev-parse --git-common-dir)"
}

# ledger_get <branch> — the branch's last reviewed sha, or nothing.
ledger_get() {
    local ledger
    ledger=$(ledger_path)
    [ -f "$ledger" ] && awk -v b="$1" '$1 == b { print $2 }' "$ledger"
    return 0
}

# ledger_lock <lock-dir> — takes the ledger lock: a mkdir, since macOS has no
# flock by default. Retries for up to 30 seconds. A lock whose recorded PID is
# no longer alive is stale and is removed.
ledger_lock() {
    local lock=$1 waited=0 pid
    while ! mkdir "$lock" 2>/dev/null; do
        pid=$(cat "$lock/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lock"
            continue
        fi
        if [ "$waited" -ge 30 ]; then
            echo "ERROR: couldn't take the review ledger lock ($lock) after 30s." >&2
            echo "If no ship or push is running, remove that directory and retry." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "$$" > "$lock/pid"
}

# ledger_set <branch> <sha> — records <sha> as <branch>'s last reviewed commit,
# or removes <branch>'s entry when <sha> is empty, holding the ledger lock. An EXIT trap removes the lock if the
# caller dies mid-write; the caller's own EXIT trap is restored afterwards.
ledger_set() {
    local branch=$1 sha=$2 ledger lock tmp prev_exit status=0
    ledger=$(ledger_path)
    lock="$ledger.lock"
    ledger_lock "$lock" || return 1
    prev_exit=$(trap -p EXIT)
    # shellcheck disable=SC2064 # expand $lock now: it's local
    trap "rm -rf '$lock'" EXIT
    tmp=$(mktemp "$ledger.XXXXXX")
    {
        [ -f "$ledger" ] && awk -v b="$branch" '$1 != b' "$ledger"
        [ -z "$sha" ] || echo "$branch $sha"
    } > "$tmp" && mv "$tmp" "$ledger" || status=1
    rm -rf "$lock"
    if [ -n "$prev_exit" ]; then
        eval "$prev_exit"
    else
        trap - EXIT
    fi
    return "$status"
}

# with_timeout <seconds> <cmd...> runs cmd and kills it after <seconds>,
# returning 124 like coreutils timeout, which macOS doesn't ship. A hung agent
# or smoke test would otherwise block forever; a timed-out run fails closed.
with_timeout() {
    local secs=$1 pid watchdog status=0 flag
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return
    fi
    flag=$(mktemp)
    rm -f "$flag"
    # <&0: a background job's stdin is otherwise /dev/null, and the command
    # may read from stdin.
    "$@" <&0 &
    pid=$!
    # Polls rather than one long sleep, so the watchdog exits within a second
    # of the command finishing instead of lingering for the full timeout.
    (
        elapsed=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$elapsed" -ge "$secs" ]; then
                touch "$flag"
                kill "$pid" 2>/dev/null
                exit 0
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
    ) &
    watchdog=$!
    wait "$pid" 2>/dev/null || status=$?
    wait "$watchdog" 2>/dev/null
    if [ -e "$flag" ]; then
        rm -f "$flag"
        return 124
    fi
    return "$status"
}
