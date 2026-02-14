#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/registry.csv"
DRY_RUN=0
MODE="pull"

usage() {
    cat <<'EOF'
Usage: repo-sync.sh [--push] [--dry-run]

Syncs managed repos in registry.csv (managed=yes only).

Modes:
  (default)    Pull: git pull existing repos, git clone missing ones
  --push       Push: git push repos that have unpushed commits

Options:
  --dry-run    Show what would happen without doing it
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --push) MODE="push"; shift ;;
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

# Update last_synced timestamp for a repo in the CSV
update_last_synced() {
    local match_path="$1"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tmpfile
    tmpfile=$(mktemp)

    local header=1
    while IFS= read -r line; do
        if [[ "$header" -eq 1 ]]; then
            echo "$line" >> "$tmpfile"
            header=0
            continue
        fi
        parse_csv_line "$line"
        if [[ "${FIELDS[1]:-}" == "$match_path" ]]; then
            # Rebuild the line with updated last_synced (field index 7)
            FIELDS[7]="$timestamp"
            local new_line=""
            for i in "${!FIELDS[@]}"; do
                [[ "$i" -gt 0 ]] && new_line+=","
                local val="${FIELDS[$i]}"
                # Quote if contains commas
                if [[ "$val" == *","* ]]; then
                    new_line+="\"$val\""
                else
                    new_line+="$val"
                fi
            done
            echo "$new_line" >> "$tmpfile"
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$REGISTRY"

    mv "$tmpfile" "$REGISTRY"
}

# --- Push mode ---
do_push() {
    local count_pushed=0
    local count_up_to_date=0
    local count_errors=0
    local count_skipped=0

    echo "repo-sync: pushing managed repos"
    [[ "$DRY_RUN" -eq 1 ]] && echo "(dry run — no changes will be made)"
    echo ""

    while IFS= read -r line; do
        parse_csv_line "$line"
        local_path="${FIELDS[1]:-}"
        managed="${FIELDS[8]:-}"
        full_path="$HOME/$local_path"
        name=$(basename "$local_path")

        if [[ -z "$local_path" ]]; then
            continue
        fi

        # Only push managed repos
        if [[ "$managed" != "yes" ]]; then
            continue
        fi

        # Skip if not a git repo
        if [[ ! -d "$full_path/.git" ]]; then
            continue
        fi

        # Check if upstream is set
        if ! git -C "$full_path" rev-parse '@{u}' >/dev/null 2>&1; then
            echo "  SKIP  $name (no upstream tracking branch)"
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # Check how many commits ahead
        local ahead
        ahead=$(git -C "$full_path" rev-list '@{u}..HEAD' --count 2>/dev/null)

        if [[ "$ahead" -eq 0 ]]; then
            count_up_to_date=$((count_up_to_date + 1))
            continue
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "  PUSH  $name ($ahead commit(s))"
            count_pushed=$((count_pushed + 1))
        else
            printf "  PUSH  %-30s " "$name"
            if output=$(git -C "$full_path" push 2>&1); then
                echo "done ($ahead commit(s))"
                update_last_synced "$local_path"
                count_pushed=$((count_pushed + 1))
            else
                echo "ERROR"
                echo "    $output" | head -3
                count_errors=$((count_errors + 1))
            fi
        fi
    done < <(tail -n +2 "$REGISTRY")

    echo ""
    echo "Done: $count_pushed pushed, $count_up_to_date up to date, $count_errors errors, $count_skipped skipped"
}

# --- Pull mode ---
do_pull() {
    local count_pulled=0
    local count_cloned=0
    local count_errors=0
    local count_skipped=0
    local count_unmanaged=0

    echo "repo-sync: syncing managed repos in registry.csv"
    [[ "$DRY_RUN" -eq 1 ]] && echo "(dry run — no changes will be made)"
    echo ""

    while IFS= read -r line; do
        parse_csv_line "$line"
        local_path="${FIELDS[1]:-}"
        repo_url="${FIELDS[0]:-}"
        managed="${FIELDS[8]:-}"
        full_path="$HOME/$local_path"
        name=$(basename "$local_path")

        if [[ -z "$repo_url" || -z "$local_path" ]]; then
            continue
        fi

        # Only sync managed repos
        if [[ "$managed" != "yes" ]]; then
            count_unmanaged=$((count_unmanaged + 1))
            continue
        fi

        if [[ -d "$full_path/.git" ]]; then
            # Repo exists — pull
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "  PULL  $name ($full_path)"
                count_pulled=$((count_pulled + 1))
            else
                printf "  PULL  %-30s " "$name"
                if output=$(git -C "$full_path" pull --ff-only 2>&1); then
                    # Summarize: "Already up to date." or show changes
                    if echo "$output" | grep -q "Already up to date"; then
                        echo "up to date"
                    else
                        echo "updated"
                    fi
                    update_last_synced "$local_path"
                    count_pulled=$((count_pulled + 1))
                else
                    echo "ERROR"
                    echo "    $output" | head -3
                    count_errors=$((count_errors + 1))
                fi
            fi
        elif [[ -d "$full_path" ]]; then
            # Directory exists but not a git repo
            echo "  SKIP  $name ($full_path exists but is not a git repo)"
            count_skipped=$((count_skipped + 1))
        else
            # Repo missing — clone
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "  CLONE $name → $full_path"
                count_cloned=$((count_cloned + 1))
            else
                printf "  CLONE %-30s " "$name"
                if output=$(git clone "$repo_url" "$full_path" 2>&1); then
                    echo "done"
                    update_last_synced "$local_path"
                    count_cloned=$((count_cloned + 1))
                else
                    echo "ERROR"
                    echo "    $output" | head -3
                    count_errors=$((count_errors + 1))
                fi
            fi
        fi
    done < <(tail -n +2 "$REGISTRY")

    echo ""
    echo "Done: $count_pulled pulled, $count_cloned cloned, $count_errors errors, $count_skipped skipped ($count_unmanaged unmanaged skipped)"
}

# Main
if [[ "$MODE" == "push" ]]; then
    do_push
else
    do_pull
fi
