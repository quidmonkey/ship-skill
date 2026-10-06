# shellcheck shell=bash
# Works out a repo's install and check commands (ship_setup and fix_checks) on
# its first ship, so a developer never has to write them. One agent call reads
# the repo's CI config, task runners and manifests, and the result is saved in
# .shiprc: later ships read it from there, so plans stay fast and the plan and
# the kickoff hash the same settings. Sourced by ship-config.sh, not executed.

toolchain_keys="ship_setup fix_checks"

# toolchain_prompt — what the discovery agent is asked. It may only read files.
read -r -d '' toolchain_prompt <<'EOF' || true
Work out how this repository installs its dependencies and runs its lint,
type-check and test commands, so an automated code review can run them in a
fresh git worktree of it. Only read files; don't run anything.

Look first at CI configuration (.github/workflows/, .gitlab-ci.yml,
azure-pipelines.yml, .circleci/, Jenkinsfile, bitbucket-pipelines.yml), since
it shows the commands the project trusts. Then Makefile, justfile or Taskfile
targets, package.json scripts, .pre-commit-config.yaml, lockfiles and
manifests, then CONTRIBUTING, README and CLAUDE.md. Use the package manager
the lockfile names (pnpm-lock.yaml means pnpm, uv.lock means uv, poetry.lock
means poetry, and so on).

SETUP is one shell command that installs the dependencies in a fresh
checkout, including whatever the repo's git hooks need. It may join steps with
&&. Use the lockfile form: npm ci, pnpm install --frozen-lockfile, uv sync,
poetry install, bundle install, go mod download. Say none if nothing needs
installing.

CHECKS are the lint, type-check and test commands, separated by ;. Each one is
a single command run from the repository root, with no cd, &&, ||, pipes,
redirection or VAR=value prefix. Prefer check modes that don't rewrite files
(for example prettier --check, ruff format --check). Leave out anything that
needs secrets, cloud credentials, a running database or service, or that
deploys. Say none if the repo shows no way to run a check; don't invent one.

Never put a # character in a command. End with exactly these three lines and
nothing after them:
SETUP: <command, or none>
CHECKS: <command;command, or none>
SOURCE: <the files you took them from, comma-separated>
EOF

# toolchain_unset — the toolchain keys .shiprc doesn't set.
toolchain_unset() {
    local key unset=""
    for key in $toolchain_keys; do
        grep -q "^$key=" "$ship_rc" 2>/dev/null || unset="$unset $key"
    done
    printf '%s\n' "${unset# }"
}

# toolchain_field <name> <output> — the value of the last "<name>: " line.
toolchain_field() {
    printf '%s\n' "$2" | sed -n "s/^$1:[[:space:]]*//p" | tail -n 1 | sed 's/[[:space:]]*$//'
}

# toolchain_valid_checks <checks> — sets checks_kept to the ;-separated checks
# that are one command each (each becomes an allow rule matched from its
# start), or none, and checks_dropped to the rest, joined with "; ".
toolchain_valid_checks() {
    local check
    checks_kept=""
    checks_dropped=""
    while IFS= read -r check; do
        check=$(printf '%s' "$check" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$check" in
            '' | none) continue ;;
            *'&'* | *'|'* | *'>'* | *'<'* | *'`'* | *'$('* | cd | cd\ * | *'#'*)
                checks_dropped="$checks_dropped${checks_dropped:+; }$check"; continue ;;
        esac
        case "${check%% *}" in
            *=*) checks_dropped="$checks_dropped${checks_dropped:+; }$check"; continue ;;
        esac
        checks_kept="$checks_kept${checks_kept:+;}$check"
    done <<< "$(printf '%s\n' "$1" | tr ';' '\n')"
    checks_kept=${checks_kept:-none}
}

# toolchain_init — detects the toolchain keys .shiprc doesn't set and appends
# them to it, with a NOTE: line for /ship to relay. A failed or malformed answer saves nothing,
# so the next ship tries again; until then the built-in defaults apply.
toolchain_init() {
    local unset out status=0 setup checks from key found found_ship_setup found_fix_checks note=""
    unset=$(toolchain_unset)
    [ -n "$unset" ] || return 0
    # Preflight reports a missing claude.
    command -v claude > /dev/null 2>&1 || return 0
    echo "Detecting this repo's install and check commands (first ship only, up to a minute)..." >&2
    # Headless and read-only, sandboxed like the review agents in code-review.sh.
    out=$(with_timeout "$(rc_value agent_timeout)" claude -p "$toolchain_prompt" \
        --model "$fix_model" --setting-sources user --permission-mode dontAsk \
        --tools "Read,Grep,Glob" --allowed-tools "Read,Grep,Glob" < /dev/null 2> /dev/null) || status=$?
    setup=$(toolchain_field SETUP "$out")
    checks=$(toolchain_field CHECKS "$out")
    from=$(toolchain_field SOURCE "$out")
    case "$setup" in *'#'*) setup="" ;; esac
    if [ "$status" -ne 0 ] || [ -z "$setup" ] || [ -z "$checks" ]; then
        echo "NOTE: couldn't detect this repo's install and check commands; the next ship tries again. Set ship_setup and fix_checks in $ship_rc to skip that."
        return 0
    fi
    toolchain_valid_checks "$checks"
    found_ship_setup=$setup
    found_fix_checks=$checks_kept
    printf '\n# Detected by the ship from %s on %s. Edit to change; none runs nothing.\n' \
        "${from:-the repo}" "$(date +%Y-%m-%d)" >> "$ship_rc"
    for key in $unset; do
        found="found_$key"
        printf '%s=%s\n' "$key" "${!found}" >> "$ship_rc"
        note="$note${note:+ and }$key=${!found}"
    done
    echo "NOTE: detected $note from ${from:-the repo}. Saved in $ship_rc."
    if in_list fix_checks "$unset" && [ -n "$checks_dropped" ]; then
        echo "NOTE: left out of fix_checks because each check must be a single command: $checks_dropped."
    fi
}
