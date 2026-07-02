#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-$HOME/github/high-level/registry.csv}"

usage() {
    cat <<'EOF'
Usage: repo-query.sh <command> [args]

Commands:
  path <repo-name>          Print absolute local path for a repo
  list [--status <s>] [--tag <t>] [--visibility <v>] [--managed]
                            List repos matching filters
  info <repo-name>          Show all fields for a repo
  unpushed                  List managed repos with unpushed commits
  csv                       Dump raw CSV (for piping)

Examples:
  repo-query.sh path homelab-gitops
  repo-query.sh list --status active --tag k3s
  repo-query.sh list --managed
  repo-query.sh info ft_transcendence
  repo-query.sh unpushed
  repo-query.sh csv | grep k3s
EOF
    exit 1
}

# Parse a CSV line handling quoted fields (for descriptions with commas)
# Sets array FIELDS with the parsed values
parse_csv_line() {
    local line="$1"
    FIELDS=()
    local field=""
    local in_quotes=0

    while IFS= read -rn1 char; do
        if [[ "$in_quotes" -eq 1 ]]; then
            if [[ "$char" == '"' ]]; then
                in_quotes=0
            else
                field+="$char"
            fi
        else
            if [[ "$char" == '"' ]]; then
                in_quotes=1
            elif [[ "$char" == ',' ]]; then
                FIELDS+=("$field")
                field=""
            else
                field+="$char"
            fi
        fi
    done <<< "$line"
    FIELDS+=("$field")
}

# Extract repo name from local_path (last component)
repo_name_from_path() {
    basename "$1"
}

# Find a repo by name (matches against the last component of local_path)
find_repo() {
    local search="$1"
    while IFS= read -r line; do
        parse_csv_line "$line"
        local path="${FIELDS[1]:-}"
        local name
        name=$(repo_name_from_path "$path")
        if [[ "$name" == "$search" ]]; then
            echo "$line"
            return 0
        fi
    done < <(tail -n +2 "$REGISTRY")
    return 1
}

cmd_path() {
    [[ $# -lt 1 ]] && { echo "Usage: repo-query.sh path <repo-name>" >&2; exit 1; }
    local search="$1"
    local line
    if line=$(find_repo "$search"); then
        parse_csv_line "$line"
        echo "$HOME/${FIELDS[1]}"
    else
        echo "repo not found: $search" >&2
        exit 1
    fi
}

cmd_list() {
    local filter_status="" filter_tag="" filter_visibility="" filter_managed=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) filter_status="$2"; shift 2 ;;
            --tag) filter_tag="$2"; shift 2 ;;
            --visibility) filter_visibility="$2"; shift 2 ;;
            --managed) filter_managed=1; shift ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    while IFS= read -r line; do
        parse_csv_line "$line"
        local path="${FIELDS[1]:-}"
        local status="${FIELDS[2]:-}"
        local visibility="${FIELDS[3]:-}"
        local tags="${FIELDS[6]:-}"
        local managed="${FIELDS[8]:-}"
        local name
        name=$(repo_name_from_path "$path")

        # Apply filters
        if [[ -n "$filter_status" && "$status" != "$filter_status" ]]; then
            continue
        fi
        if [[ -n "$filter_visibility" && "$visibility" != "$filter_visibility" ]]; then
            continue
        fi
        if [[ -n "$filter_tag" ]]; then
            if ! echo "$tags" | grep -q "$filter_tag"; then
                continue
            fi
        fi
        if [[ "$filter_managed" -eq 1 && "$managed" != "yes" ]]; then
            continue
        fi

        echo "$name"
    done < <(tail -n +2 "$REGISTRY")
}

cmd_info() {
    [[ $# -lt 1 ]] && { echo "Usage: repo-query.sh info <repo-name>" >&2; exit 1; }
    local search="$1"
    local line
    if line=$(find_repo "$search"); then
        parse_csv_line "$line"
        echo "repo_url:      ${FIELDS[0]:-}"
        echo "local_path:    $HOME/${FIELDS[1]:-}"
        echo "status:        ${FIELDS[2]:-}"
        echo "visibility:    ${FIELDS[3]:-}"
        echo "k3s_deployed:  ${FIELDS[4]:-}"
        echo "description:   ${FIELDS[5]:-}"
        echo "tags:          ${FIELDS[6]:-}"
        echo "last_synced:   ${FIELDS[7]:-}"
        echo "managed:       ${FIELDS[8]:-}"
    else
        echo "repo not found: $search" >&2
        exit 1
    fi
}

cmd_unpushed() {
    local count_ahead=0
    local count_dirty=0
    local count_no_upstream=0
    local count_clean=0

    echo "Checking managed repos for unpushed changes..."
    echo ""

    while IFS= read -r line; do
        parse_csv_line "$line"
        local path="${FIELDS[1]:-}"
        local managed="${FIELDS[8]:-}"
        local full_path="$HOME/$path"
        local name
        name=$(repo_name_from_path "$path")

        # Only check managed repos
        if [[ "$managed" != "yes" ]]; then
            continue
        fi

        # Skip if not a git repo
        if [[ ! -d "$full_path/.git" ]]; then
            continue
        fi

        local issues=""

        # Check for uncommitted changes (staged or unstaged)
        if ! git -C "$full_path" diff --quiet 2>/dev/null || \
           ! git -C "$full_path" diff --cached --quiet 2>/dev/null; then
            issues+="uncommitted changes"
            count_dirty=$((count_dirty + 1))
        fi

        # Check for untracked files
        local untracked
        untracked=$(git -C "$full_path" ls-files --others --exclude-standard 2>/dev/null | head -1)
        if [[ -n "$untracked" ]]; then
            if [[ -n "$issues" ]]; then
                issues+=", "
            fi
            issues+="untracked files"
        fi

        # Check for unpushed commits
        if git -C "$full_path" rev-parse '@{u}' >/dev/null 2>&1; then
            local ahead
            ahead=$(git -C "$full_path" rev-list '@{u}..HEAD' --count 2>/dev/null)
            if [[ "$ahead" -gt 0 ]]; then
                if [[ -n "$issues" ]]; then
                    issues+=", "
                fi
                issues+="$ahead unpushed commit(s)"
                count_ahead=$((count_ahead + 1))
            fi
        else
            if [[ -n "$issues" ]]; then
                issues+=", "
            fi
            issues+="no upstream"
            count_no_upstream=$((count_no_upstream + 1))
        fi

        if [[ -n "$issues" ]]; then
            printf "  %-35s %s\n" "$name" "$issues"
        else
            count_clean=$((count_clean + 1))
        fi
    done < <(tail -n +2 "$REGISTRY")

    echo ""
    echo "Summary: $count_ahead ahead, $count_dirty dirty, $count_no_upstream no upstream, $count_clean clean"
}

cmd_csv() {
    cat "$REGISTRY"
}

# Main
[[ $# -lt 1 ]] && usage

command="$1"
shift

case "$command" in
    path)     cmd_path "$@" ;;
    list)     cmd_list "$@" ;;
    info)     cmd_info "$@" ;;
    unpushed) cmd_unpushed ;;
    csv)      cmd_csv ;;
    *)        usage ;;
esac
