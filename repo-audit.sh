#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-$HOME/github/high-level/registry.csv}"
ACTIVE_DAYS=14

usage() {
    cat <<'EOF'
Usage: repo-audit.sh [--days N]

Audits registry.csv and updates:
  - status: "active" if last commit within N days (default 14), "archived" otherwise
  - visibility: fills in missing values via gh repo view

Options:
  --days N    Number of days to consider "active" (default: 14)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) ACTIVE_DAYS="$2"; shift 2 ;;
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

# Rebuild a CSV line from FIELDS array
rebuild_csv_line() {
    local new_line=""
    for i in "${!FIELDS[@]}"; do
        [[ "$i" -gt 0 ]] && new_line+=","
        val="${FIELDS[$i]}"
        if [[ "$val" == *","* ]]; then
            new_line+="\"$val\""
        else
            new_line+="$val"
        fi
    done
    echo "$new_line"
}

# Extract owner/repo from SSH URL
# git@github.com:jackwaddington/foo.git → jackwaddington/foo
owner_repo_from_url() {
    local url="$1"
    echo "$url" | sed 's|git@github.com:||; s|\.git$||'
}

cutoff_epoch=$(date -d "$ACTIVE_DAYS days ago" +%s)

count_status=0
count_visibility=0
count_total=0

echo "repo-audit: checking status and visibility for all repos"
echo "  active threshold: $ACTIVE_DAYS days"
echo ""

tmpfile=$(mktemp)
header=1

while IFS= read -r line; do
    if [[ "$header" -eq 1 ]]; then
        echo "$line" >> "$tmpfile"
        header=0
        continue
    fi

    parse_csv_line "$line"
    repo_url="${FIELDS[0]:-}"
    local_path="${FIELDS[1]:-}"
    old_status="${FIELDS[2]:-}"
    old_visibility="${FIELDS[3]:-}"
    full_path="$HOME/$local_path"
    name=$(basename "$local_path")
    count_total=$((count_total + 1))

    changed=0

    # --- Status: check last commit date ---
    if [[ -d "$full_path/.git" ]]; then
        last_commit_epoch=$(git -C "$full_path" log -1 --format=%ct 2>/dev/null || echo "0")
        if [[ "$last_commit_epoch" -ge "$cutoff_epoch" ]]; then
            new_status="active"
        else
            new_status="archived"
        fi
        if [[ "$old_status" != "$new_status" ]]; then
            FIELDS[2]="$new_status"
            printf "  STATUS  %-35s %s → %s\n" "$name" "$old_status" "$new_status"
            count_status=$((count_status + 1))
            changed=1
        fi
    fi

    # --- Visibility: fill if empty ---
    if [[ -z "$old_visibility" && -n "$repo_url" ]]; then
        owner_repo=$(owner_repo_from_url "$repo_url")
        if is_private=$(gh repo view "$owner_repo" --json isPrivate --jq '.isPrivate' 2>/dev/null); then
            if [[ "$is_private" == "true" ]]; then
                new_visibility="private"
            else
                new_visibility="public"
            fi
            FIELDS[3]="$new_visibility"
            printf "  VISIBILITY  %-30s → %s\n" "$name" "$new_visibility"
            count_visibility=$((count_visibility + 1))
            changed=1
        else
            printf "  VISIBILITY  %-30s → FAILED (repo may not exist on GitHub)\n" "$name"
        fi
    fi

    if [[ "$changed" -eq 1 ]]; then
        rebuild_csv_line >> "$tmpfile"
    else
        echo "$line" >> "$tmpfile"
    fi
done < "$REGISTRY"

mv "$tmpfile" "$REGISTRY"

echo ""
echo "Done: $count_total repos checked, $count_status status changes, $count_visibility visibility fills"
