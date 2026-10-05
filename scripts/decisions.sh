#!/usr/bin/env bash
# Prints the decisions recorded in commit-message trailers (README.md,
# "Decision history") for the commits that touched the given paths.
#
#   scripts/decisions.sh [--limit N] [--range <rev-range>] [--] [<path>...]
#   scripts/decisions.sh --trailers --range <rev-range>
#
# Default output, newest first, one entry per commit that has a Decision or
# Rejected trailer:
#   a1b2c3d 2026-09-24 Jane Doe: Route Firestore writes through repo/
#     Decision: ...
#     Rejected: ...
#
# --limit N   stop after N entries and say how many were left out
# --range R   only commits in R (default: all history reachable from HEAD)
# --trailers  print only the unique trailer lines, oldest first, as one block
#             that can end a commit message (ship.sh uses it for squash merges)
#
# With no paths, every commit counts. A single file path follows renames.
# Commits without a Decision or Rejected trailer print nothing.
set -uo pipefail

keys="key=Decision,key=Rejected,key=Agent,key=Session"
limit=0
range=()
trailers_only=false

while [ $# -gt 0 ]; do
    case "$1" in
        --limit) limit=$2; shift 2 ;;
        --range) range=("$2"); shift 2 ;;
        --trailers) trailers_only=true; shift ;;
        --) shift; break ;;
        -*) echo "decisions.sh: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

follow=()
[ $# -eq 1 ] && [ -f "$1" ] && follow=(--follow)

# Oldest first for --trailers, so a later decision that supersedes an earlier
# one reads after it in the squash commit.
order=()
$trailers_only && order=(--reverse)

# Records split on \036, fields on \037. %(trailers) prints only the keys asked
# for, and only from the message's final paragraph, which is where git (and
# every other trailer reader) looks for them.
git log --date=short --format="%x1e%h %ad %an%x1f%s%x1f%(trailers:$keys)" \
    ${order[@]+"${order[@]}"} ${follow[@]+"${follow[@]}"} ${range[@]+"${range[@]}"} -- "$@" 2>/dev/null |
    awk -v limit="$limit" -v trailers_only="$trailers_only" 'BEGIN { RS = "\036"; FS = "\037" }
        tolower($3) ~ /(^|\n)(decision|rejected):/ {
            n++
            if (limit > 0 && n > limit) next
            count = split($3, lines, "\n")
            if (trailers_only == "true") {
                # Agent and Session repeat across commits; keep one of each.
                for (i = 1; i <= count; i++) if (lines[i] != "" && !seen[lines[i]]++) print lines[i]
                next
            }
            printf "%s: %s\n", $1, $2
            for (i = 1; i <= count; i++) if (lines[i] != "") printf "  %s\n", lines[i]
        }
        END {
            if (limit > 0 && n > limit)
                printf "(%d older decisions not shown; run scripts/decisions.sh on the path for all of them)\n", n - limit
        }'
