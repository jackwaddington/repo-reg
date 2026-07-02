#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-$HOME/github/high-level/registry.csv}"
GITHUB_DIR="$HOME/github"
CONFIRM=0

usage() {
    cat <<'EOF'
Usage: repo-cleanup.sh [--confirm]

Finds directories in ~/github/ that are NOT tracked in registry.csv.
By default shows what would be removed (dry run).

Only removes directories that are fully backed up:
  - All changes committed
  - All commits pushed to remote
  - Non-git directories are always flagged for review

Options:
  --confirm    Actually delete safe-to-remove directories
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm) CONFIRM=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Parse a CSV line handling quoted fields
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

# Build set of tracked directory names from registry (bash 3 compatible)
TRACKED_DIRS=""
if [[ -f "$REGISTRY" ]]; then
    while IFS= read -r line; do
        parse_csv_line "$line"
        local_path="${FIELDS[1]:-}"
        name=$(basename "$local_path")
        TRACKED_DIRS+="$name"$'\n'
    done < <(tail -n +2 "$REGISTRY")
fi

echo "repo-cleanup: scanning ~/github/ for untracked directories"
[[ "$CONFIRM" -eq 0 ]] && echo "(dry run — pass --confirm to delete)"
echo ""

count_safe=0
count_dirty=0
count_no_git=0

for dir in "$GITHUB_DIR"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")

    # Skip if tracked in registry
    if echo "$TRACKED_DIRS" | grep -qx "$name" 2>/dev/null; then
        continue
    fi

    # Not tracked — check if safe to remove
    if [[ ! -d "$dir/.git" ]]; then
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  REVIEW  $name ($size) — not a git repo, manual review needed"
        count_no_git=$((count_no_git + 1))
        continue
    fi

    # It's a git repo — check for uncommitted changes
    issues=""

    if ! git -C "$dir" diff --quiet 2>/dev/null || \
       ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        issues+="uncommitted changes"
    fi

    # Check for untracked files
    untracked=$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null | head -1)
    if [[ -n "$untracked" ]]; then
        [[ -n "$issues" ]] && issues+=", "
        issues+="untracked files"
    fi

    # Check for unpushed commits
    if git -C "$dir" rev-parse '@{u}' >/dev/null 2>&1; then
        ahead=$(git -C "$dir" rev-list '@{u}..HEAD' --count 2>/dev/null)
        if [[ "$ahead" -gt 0 ]]; then
            [[ -n "$issues" ]] && issues+=", "
            issues+="$ahead unpushed commit(s)"
        fi
    else
        [[ -n "$issues" ]] && issues+=", "
        issues+="no upstream (cannot verify pushed)"
    fi

    size=$(du -sh "$dir" 2>/dev/null | cut -f1)

    if [[ -n "$issues" ]]; then
        echo "  KEEP    $name ($size) — $issues"
        count_dirty=$((count_dirty + 1))
    else
        if [[ "$CONFIRM" -eq 1 ]]; then
            echo "  DELETE  $name ($size)"
            rm -rf "$dir"
        else
            echo "  DELETE  $name ($size) — fully backed up, safe to remove"
        fi
        count_safe=$((count_safe + 1))
    fi
done

echo ""
echo "Summary: $count_safe safe to delete, $count_dirty have unpushed work, $count_no_git not git repos"
[[ "$CONFIRM" -eq 0 && "$count_safe" -gt 0 ]] && echo "Run with --confirm to delete the $count_safe safe directories"
