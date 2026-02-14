#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/registry.csv"
GITHUB_USER="your-username"
UPDATE_EXISTING=0
PUSH_DESCRIPTIONS=0

usage() {
    cat <<'EOF'
Usage: repo-discover.sh [--update] [--push]

Discovers all repos from GitHub API and adds missing ones to registry.csv.
Requires: gh CLI (brew install gh / sudo apt install gh)

Options:
  --update    Also update description for existing entries from GitHub
  --push      Push descriptions from CSV to GitHub (managed repos only)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) UPDATE_EXISTING=1; shift ;;
        --push) PUSH_DESCRIPTIONS=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Check gh is installed and authenticated
if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI not found. Install it:" >&2
    echo "  sudo apt install gh   # Debian/Ubuntu" >&2
    echo "  brew install gh       # macOS" >&2
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI not authenticated. Run: gh auth login" >&2
    exit 1
fi

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

# Skip discovery if only pushing
if [[ "$PUSH_DESCRIPTIONS" -eq 1 && "$UPDATE_EXISTING" -eq 0 ]]; then
    # Jump straight to push logic (no discovery needed)
    echo "repo-discover: push-only mode, skipping discovery..."
else

# Build a set of repo names already in the registry
EXISTING_NAMES=""
if [[ -f "$REGISTRY" ]]; then
    while IFS= read -r line; do
        parse_csv_line "$line"
        local_path="${FIELDS[1]:-}"
        name=$(basename "$local_path")
        EXISTING_NAMES+="$name"$'\n'
    done < <(tail -n +2 "$REGISTRY")
fi

echo "repo-discover: fetching repos for $GITHUB_USER from GitHub..."

# Fetch all repos via gh CLI
repos_json=$(gh repo list "$GITHUB_USER" --limit 1000 --json name,sshUrl,isPrivate,description)

count_new=0
count_existing=0
count_updated=0

# Create registry if it doesn't exist
if [[ ! -f "$REGISTRY" ]]; then
    echo "repo_url,local_path,status,visibility,k3s_deployed,description,tags,last_synced,managed" > "$REGISTRY"
fi

# Process each repo
while IFS= read -r repo; do
    name=$(echo "$repo" | cut -d'|' -f1)
    ssh_url=$(echo "$repo" | cut -d'|' -f2)
    is_private=$(echo "$repo" | cut -d'|' -f3)
    description=$(echo "$repo" | cut -d'|' -f4)

    if echo "$EXISTING_NAMES" | grep -qx "$name" 2>/dev/null; then
        count_existing=$((count_existing + 1))

        if [[ "$UPDATE_EXISTING" -eq 1 ]]; then
            # Update visibility and description for existing entry
            new_visibility="public"
            [[ "$is_private" == "true" ]] && new_visibility="private"

            tmpfile=$(mktemp)
            header=1
            updated=0
            while IFS= read -r line; do
                if [[ "$header" -eq 1 ]]; then
                    echo "$line" >> "$tmpfile"
                    header=0
                    continue
                fi
                parse_csv_line "$line"
                local_path="${FIELDS[1]:-}"
                entry_name=$(basename "$local_path")
                if [[ "$entry_name" == "$name" ]]; then
                    # Update visibility always
                    if [[ "${FIELDS[3]:-}" != "$new_visibility" ]]; then
                        FIELDS[3]="$new_visibility"
                        updated=1
                    fi
                    # Update description only if currently empty
                    if [[ -z "${FIELDS[5]:-}" && -n "$description" ]]; then
                        FIELDS[5]="$description"
                        updated=1
                    fi
                    new_line=""
                    for i in "${!FIELDS[@]}"; do
                        [[ "$i" -gt 0 ]] && new_line+=","
                        val="${FIELDS[$i]}"
                        if [[ "$val" == *","* ]]; then
                            new_line+="\"$val\""
                        else
                            new_line+="$val"
                        fi
                    done
                    echo "$new_line" >> "$tmpfile"
                    if [[ "$updated" -eq 1 ]]; then
                        count_updated=$((count_updated + 1))
                    fi
                else
                    echo "$line" >> "$tmpfile"
                fi
            done < "$REGISTRY"
            mv "$tmpfile" "$REGISTRY"
        fi
    else
        # New repo — add to registry
        visibility="public"
        if [[ "$is_private" == "true" ]]; then
            visibility="private"
        fi

        # Quote description if it contains commas
        desc_field="$description"
        if [[ "$desc_field" == *","* ]]; then
            desc_field="\"$desc_field\""
        fi

        echo "$ssh_url,github/$name,archived,$visibility,no,$desc_field,,,yes" >> "$REGISTRY"
        local_visibility="public"
        [[ "$is_private" == "true" ]] && local_visibility="private"
        echo "  NEW   $name ($local_visibility)"
        count_new=$((count_new + 1))
    fi
done < <(echo "$repos_json" | python3 -c "
import json, sys
repos = json.load(sys.stdin)
for r in repos:
    desc = (r.get('description') or '').replace('|', ' ')
    private = str(r.get('isPrivate', False)).lower()
    print(f\"{r['name']}|{r['sshUrl']}|{private}|{desc}\")
")

echo ""
echo "Done: $count_new new, $count_existing already tracked"
[[ "$UPDATE_EXISTING" -eq 1 ]] && echo "  $count_updated descriptions updated"

fi # end of discovery block

# Push descriptions from CSV to GitHub
if [[ "$PUSH_DESCRIPTIONS" -eq 1 ]]; then
    echo ""
    echo "Pushing descriptions from CSV to GitHub (managed repos only)..."
    count_pushed=0
    count_skipped=0

    while IFS= read -r line; do
        parse_csv_line "$line"
        repo_url="${FIELDS[0]:-}"
        managed="${FIELDS[8]:-}"
        description="${FIELDS[5]:-}"

        [[ "$managed" != "yes" ]] && continue

        # Extract owner/repo from SSH URL (git@github.com:owner/repo.git)
        repo_slug=$(echo "$repo_url" | sed 's/.*://' | sed 's/\.git$//')

        if [[ -z "$description" ]]; then
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # Get current GitHub description
        gh_desc=$(gh repo view "$repo_slug" --json description -q '.description // ""' 2>/dev/null || echo "")

        if [[ "$gh_desc" == "$description" ]]; then
            count_skipped=$((count_skipped + 1))
            continue
        fi

        echo "  PUSH  $repo_slug"
        echo "        \"$description\""
        if gh repo edit "$repo_slug" --description "$description" >/dev/null 2>&1; then
            count_pushed=$((count_pushed + 1))
        else
            echo "        FAILED (check repo permissions)"
            count_skipped=$((count_skipped + 1))
        fi
    done < <(tail -n +2 "$REGISTRY")

    echo ""
    echo "Push done: $count_pushed updated, $count_skipped unchanged/empty"
fi
