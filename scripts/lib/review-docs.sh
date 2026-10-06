# shellcheck shell=bash
# Finds the documents that state a project's intended behavior, for the
# code review and the ship plan. Repos keep them in different places, or have
# none, so review_docs=auto checks the common ones. Sourced, not executed.

# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

review_doc_candidates="docs doc ARCHITECTURE.md DESIGN.md README.md"

# review_doc_sources <review_docs> <rev> — sets doc_sources to the documents
# found in commit <rev>, and no_docs_reason to why there are none. <review_docs>
# is auto (or empty), none, or space-separated paths; a named path missing from
# <rev> is left out and listed in doc_missing for the caller to warn about.
# Checked in the commit, not the working tree, so the plan and the review see
# the same documents.
review_doc_sources() {
    local mode=${1:-auto} rev=$2 d
    doc_sources=()
    doc_missing=""
    case "$mode" in
        auto)
            for d in $review_doc_candidates; do
                git cat-file -e "$rev:$d" 2>/dev/null && doc_sources+=("$d")
            done
            no_docs_reason="none of $review_doc_candidates exists"
            ;;
        none) no_docs_reason="review_docs=none" ;;
        *)
            for d in $mode; do
                d=${d%/}
                if git cat-file -e "$rev:$d" 2>/dev/null; then
                    doc_sources+=("$d")
                else
                    doc_missing="$doc_missing $d"
                fi
            done
            no_docs_reason="none of the review_docs paths exists"
            ;;
    esac
}

# review_docs_summary — doc_sources on one line, or why there are none.
review_docs_summary() {
    if [ "${#doc_sources[@]}" -gt 0 ]; then
        local IFS=,
        printf '%s\n' "${doc_sources[*]}" | sed 's/,/, /g'
    else
        printf '(none: %s)\n' "$no_docs_reason"
    fi
}
