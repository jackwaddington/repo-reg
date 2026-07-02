#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-$HOME/github/high-level/registry.csv}"
CONFIRM=0

# Load config
# shellcheck source=.env
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
GITHUB_USER="${GITHUB_USER:-}"
[[ -z "$GITHUB_USER" ]] && { echo "Error: GITHUB_USER not set. Copy .env.example to .env and fill it in."; exit 1; }

usage() {
    cat <<'EOF'
Usage: repo-create.sh [--confirm]

Creates GitHub repos for managed registry entries that don't yet exist on GitHub.
For each new repo: creates it on GitHub, initialises locally with a README, and pushes.

Dry-run by default — pass --confirm to actually create.

Options:
  --confirm   Actually create repos (default is dry-run)
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

if [[ ! -f "$REGISTRY" ]]; then
    echo "Error: registry.csv not found at $REGISTRY" >&2
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

if [[ "$CONFIRM" -eq 0 ]]; then
    echo "repo-create: DRY RUN — pass --confirm to actually create repos"
    echo ""
fi

count_new=0
count_skipped=0
count_exists=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    parse_csv_line "$line"
    repo_url="${FIELDS[0]:-}"
    local_path="${FIELDS[1]:-}"
    status="${FIELDS[2]:-}"
    visibility="${FIELDS[3]:-}"
    description="${FIELDS[5]:-}"
    managed="${FIELDS[8]:-}"

    [[ "$managed" != "yes" ]] && continue

    # Extract repo name from SSH URL
    name=$(basename "$repo_url" .git)

    # Check if repo already exists on GitHub
    if gh repo view "$GITHUB_USER/$name" &>/dev/null 2>&1; then
        echo "  EXISTS  $name"
        count_exists=$((count_exists + 1))
        continue
    fi

    # Determine visibility flag
    vis_flag="--public"
    [[ "$visibility" == "private" ]] && vis_flag="--private"

    local_dir="$HOME/$local_path"

    if [[ "$CONFIRM" -eq 0 ]]; then
        echo "  CREATE  $name ($visibility) — \"$description\""
        echo "          local: $local_dir"
        count_new=$((count_new + 1))
    else
        echo "  CREATE  $name ($visibility)..."

        # Create repo on GitHub
        gh repo create "$GITHUB_USER/$name" $vis_flag --description "$description" --confirm 2>/dev/null \
            || gh repo create "$name" $vis_flag --description "$description" 2>/dev/null \
            || { echo "          FAILED to create on GitHub"; count_skipped=$((count_skipped + 1)); continue; }

        # Initialise locally
        mkdir -p "$local_dir"
        cd "$local_dir"

        if [[ ! -d ".git" ]]; then
            git init -b main
            cat > README.md <<README
# $name

$description
README
            git add README.md
            git commit -m "Initial commit"
            git remote add origin "$repo_url"
            git push -u origin main
            echo "          pushed initial commit"
        else
            echo "          local dir exists with git — skipping init"
        fi

        cd "$SCRIPT_DIR"

        # Update last_synced in CSV
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        tmpfile=$(mktemp)
        while IFS= read -r csvline; do
            parse_csv_line "$csvline"
            row_url="${FIELDS[0]:-}"
            if [[ "$row_url" == "$repo_url" ]]; then
                # Rebuild row with updated last_synced (field 7)
                echo "${FIELDS[0]},${FIELDS[1]},${FIELDS[2]},${FIELDS[3]},${FIELDS[4]},${FIELDS[5]},${FIELDS[6]},$timestamp,${FIELDS[8]}" >> "$tmpfile"
            else
                echo "$csvline" >> "$tmpfile"
            fi
        done < "$REGISTRY"
        mv "$tmpfile" "$REGISTRY"

        count_new=$((count_new + 1))
    fi

done < <(tail -n +2 "$REGISTRY")

echo ""
if [[ "$CONFIRM" -eq 0 ]]; then
    echo "Dry run: $count_new would be created, $count_exists already exist on GitHub"
    echo "Run with --confirm to create."
else
    echo "Done: $count_new created, $count_exists already existed, $count_skipped failed"
fi
