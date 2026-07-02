#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-$HOME/github/high-level/registry.csv}"
OUTPUT="${OUTPUT:-$HOME/github/high-level/MAP.md}"

# Load config
# shellcheck source=.env
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
GITHUB_USER="${GITHUB_USER:-}"
[[ -z "$GITHUB_USER" ]] && { echo "Error: GITHUB_USER not set. Copy .env.example to .env and fill it in."; exit 1; }
# BFS mode: follow links outward from this repo, suppress reverse edges.
# Set to your GitHub profile repo name (e.g. "jackwaddington"). Ignores MAP_TAGS when set.
ROOT_REPO="${ROOT_REPO:-}"
# Fallback tag filter when ROOT_REPO is not set (space-separated). Empty = all managed repos.
MAP_TAGS="${MAP_TAGS:-}"

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

# Sanitize repo name for Mermaid node ID
sanitize_id() {
    echo "$1" | tr '-' '_' | tr '.' '_' | sed 's/^[0-9]/_&/'
}

# --- Configuration ---

EXCLUDE_TAGS="personal dev portfolio"
EXCLUDE_PATTERN=$(echo "$EXCLUDE_TAGS" | tr ' ' '|')

# Repos that reference everything (index/meta repos) — skip as edge sources
SKIP_SOURCES="repo-registry repo-reg ${GITHUB_USER}"

# --- Phase 1: Gather ALL managed repos ---
# In BFS mode we need to know about every repo so we can follow links to any of them.
# In MAP_TAGS mode we filter here to only the tagged subset.

ALL_REPOS_PATHS=""   # name:path for every managed repo (used by BFS traversal)
ALL_REPOS_NAMES=""   # every managed repo name (for link-target validation)

REPO_PATHS=""  # filtered set for non-BFS mode
REPO_NAMES=""
REPO_TAGS=""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    parse_csv_line "$line"
    managed="${FIELDS[8]:-}"
    [[ "$managed" != "yes" ]] && continue

    path="${FIELDS[1]:-}"
    tags="${FIELDS[6]:-}"
    name=$(basename "$path")

    # Always add to the full set (needed for BFS link validation)
    ALL_REPOS_PATHS+="$name:$HOME/$path"$'\n'
    ALL_REPOS_NAMES+="$name"$'\n'

    # For MAP_TAGS mode, also build the filtered set
    if [[ -z "$ROOT_REPO" ]]; then
        if [[ -n "$MAP_TAGS" ]]; then
            matched=0
            for mt in $MAP_TAGS; do
                if [[ ";${tags};" == *";${mt};"* ]]; then
                    matched=1
                    break
                fi
            done
            [[ "$matched" -eq 0 ]] && continue
        fi
        REPO_NAMES+="$name"$'\n'
        REPO_PATHS+="$name:$HOME/$path"$'\n'
        REPO_TAGS+="$name:$tags"$'\n'
    fi
done < <(tail -n +2 "$REGISTRY")

ALL_UNIQUE_NAMES=$(echo "$ALL_REPOS_NAMES" | sort -u | grep -v '^$')

# --- Phase 2: Discover edges ---

echo "Scanning repos for cross-references..."
EDGES=""

# Scan a local repo directory for jackwaddington/repo-name references
scan_refs() {
    local source_path="$1"
    [[ ! -d "$source_path" ]] && return
    find "$source_path" -maxdepth 2 -type f ! -path '*/.git/*' \
        -exec grep -lI "${GITHUB_USER}/" {} + 2>/dev/null \
        | xargs grep -oh "${GITHUB_USER}/[A-Za-z0-9_.-]*" 2>/dev/null \
        | sed "s|${GITHUB_USER}/||" \
        | sort -u || true
}

get_repo_path() {
    echo "$ALL_REPOS_PATHS" | grep "^${1}:" | head -1 | cut -d':' -f2-
}

if [[ -n "$ROOT_REPO" ]]; then
    # --- BFS mode ---
    # Process repos in breadth-first order from ROOT_REPO.
    # Only add forward edges: if A→B is already recorded, suppress B→A.
    BFS_QUEUE=("$ROOT_REPO")
    BFS_VISITED=""
    INCLUDED_NODES=""

    bfs_idx=0
    while [[ $bfs_idx -lt ${#BFS_QUEUE[@]} ]]; do
        current="${BFS_QUEUE[$bfs_idx]}"
        bfs_idx=$((bfs_idx + 1))

        # Skip if already visited
        echo "$BFS_VISITED" | grep -qx "$current" 2>/dev/null && continue
        BFS_VISITED+="$current"$'\n'
        INCLUDED_NODES+="$current"$'\n'

        # Skip meta repos as edge sources (but never skip the root itself)
        if [[ "$current" != "$ROOT_REPO" ]]; then
            echo "$SKIP_SOURCES" | grep -qw "$current" 2>/dev/null && continue
        fi

        source_path=$(get_repo_path "$current")
        [[ -z "$source_path" || ! -d "$source_path" ]] && continue

        while IFS= read -r target_name; do
            [[ -z "$target_name" ]] && continue
            target_name="${target_name%.git}"
            [[ "$target_name" == "$current" ]] && continue

            # Only known repos
            echo "$ALL_UNIQUE_NAMES" | grep -qx "$target_name" 2>/dev/null || continue

            # Suppress reverse edges: skip if target→current already exists
            if echo "$EDGES" | grep -q "^${target_name},${current}$" 2>/dev/null; then
                continue
            fi

            edge_key="${current},${target_name}"
            if ! echo "$EDGES" | grep -q "^${edge_key}$" 2>/dev/null; then
                EDGES+="${edge_key}"$'\n'
                echo "  $current --> $target_name"
            fi

            # Queue target if not yet visited
            echo "$BFS_VISITED" | grep -qx "$target_name" 2>/dev/null || BFS_QUEUE+=("$target_name")

        done < <(scan_refs "$source_path")
    done

    # Build REPO_TAGS and ALL_TAGS from only the visited nodes
    ALL_TAGS=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_csv_line "$line"
        managed="${FIELDS[8]:-}"
        [[ "$managed" != "yes" ]] && continue
        path="${FIELDS[1]:-}"
        tags="${FIELDS[6]:-}"
        name=$(basename "$path")
        echo "$INCLUDED_NODES" | grep -qx "$name" 2>/dev/null || continue
        REPO_TAGS+="$name:$tags"$'\n'
        REPO_NAMES+="$name"$'\n'
        if [[ -n "$tags" ]]; then
            IFS=';' read -ra tag_arr <<< "$tags"
            for tag in "${tag_arr[@]}"; do
                tag=$(echo "$tag" | xargs)
                ALL_TAGS+="$tag"$'\n'
            done
        fi
    done < <(tail -n +2 "$REGISTRY")

else
    # --- MAP_TAGS / scan-all mode ---
    ALL_TAGS=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        name=$(echo "$entry" | cut -d':' -f1)
        tags=$(echo "$REPO_TAGS" | grep "^${name}:" | cut -d':' -f2-)
        if [[ -n "$tags" ]]; then
            IFS=';' read -ra tag_arr <<< "$tags"
            for tag in "${tag_arr[@]}"; do
                tag=$(echo "$tag" | xargs)
                ALL_TAGS+="$tag"$'\n'
            done
        fi
    done <<< "$REPO_NAMES"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        source_name=$(echo "$entry" | cut -d':' -f1)
        source_path=$(echo "$entry" | cut -d':' -f2-)
        [[ ! -d "$source_path" ]] && continue
        echo "$SKIP_SOURCES" | grep -qw "$source_name" 2>/dev/null && continue

        UNIQUE_NAMES=$(echo "$REPO_NAMES" | sort -u | grep -v '^$')
        while IFS= read -r target_name; do
            [[ -z "$target_name" ]] && continue
            target_name="${target_name%.git}"
            [[ "$target_name" == "$source_name" ]] && continue
            if echo "$UNIQUE_NAMES" | grep -qx "$target_name" 2>/dev/null; then
                edge_key="${source_name},${target_name}"
                if ! echo "$EDGES" | grep -q "^${edge_key}$" 2>/dev/null; then
                    EDGES+="${edge_key}"$'\n'
                    echo "  $source_name --> $target_name"
                fi
            fi
        done < <(scan_refs "$source_path")
    done <<< "$REPO_PATHS"

    # Rebuild ALL_TAGS from REPO_TAGS
    ALL_TAGS=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        tags=$(echo "$entry" | cut -d':' -f2-)
        if [[ -n "$tags" ]]; then
            IFS=';' read -ra tag_arr <<< "$tags"
            for tag in "${tag_arr[@]}"; do
                tag=$(echo "$tag" | xargs)
                ALL_TAGS+="$tag"$'\n'
            done
        fi
    done <<< "$REPO_TAGS"
fi

echo ""

SORTED_TAGS=$(echo "$ALL_TAGS" | sort -u | grep -v '^$' | grep -Ev "^(${EXCLUDE_PATTERN})$" || true)

# --- Phase 3: Group repos by primary tag ---

PRINTED=""

is_printed() {
    echo "$PRINTED" | grep -qx "$1" 2>/dev/null
}

mark_printed() {
    PRINTED+="$1"$'\n'
}

# --- Phase 4: Render Mermaid ---

{
    echo "# Repository Map"
    echo ""
    if [[ -n "$ROOT_REPO" ]]; then
        echo "*Auto-generated by repo-map.sh — BFS from \`${ROOT_REPO}\`, forward edges only.*"
    else
        echo "*Auto-generated by repo-map.sh — regenerate with \`./repo-map.sh\`*"
        echo "*Edges discovered by scanning repos for \`${GITHUB_USER}/repo-name\` references.*"
    fi
    echo ""
    echo '```mermaid'
    echo "graph LR"

    # Subgraphs by tag
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        group_nodes=""
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            name=$(echo "$entry" | cut -d':' -f1)
            tags=$(echo "$entry" | cut -d':' -f2-)

            has_tag=0
            if [[ -n "$tags" ]]; then
                IFS=';' read -ra tag_arr <<< "$tags"
                for t in "${tag_arr[@]}"; do
                    t=$(echo "$t" | xargs)
                    [[ "$t" == "$tag" ]] && has_tag=1
                done
            fi
            [[ "$has_tag" -eq 0 ]] && continue

            if ! is_printed "$name"; then
                sid=$(sanitize_id "$name")
                if [[ "$sid" != "$name" ]]; then
                    group_nodes+="        ${sid}[\"${name}\"]"$'\n'
                else
                    group_nodes+="        ${sid}"$'\n'
                fi
                mark_printed "$name"
            fi
        done <<< "$REPO_TAGS"

        if [[ -n "$group_nodes" ]]; then
            echo "    subgraph ${tag}"
            echo -n "$group_nodes"
            echo "    end"
        fi
    done <<< "$SORTED_TAGS"

    # Untagged / orphan repos
    orphan_nodes=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        name=$(echo "$entry" | cut -d':' -f1)
        if ! is_printed "$name"; then
            sid=$(sanitize_id "$name")
            if [[ "$sid" != "$name" ]]; then
                orphan_nodes+="        ${sid}[\"${name}\"]"$'\n'
            else
                orphan_nodes+="        ${sid}"$'\n'
            fi
            mark_printed "$name"
        fi
    done <<< "$REPO_TAGS"

    if [[ -n "$orphan_nodes" ]]; then
        echo "    subgraph untagged"
        echo -n "$orphan_nodes"
        echo "    end"
    fi

    # Edges
    echo ""
    while IFS= read -r edge; do
        [[ -z "$edge" ]] && continue
        source=$(echo "$edge" | cut -d',' -f1)
        target=$(echo "$edge" | cut -d',' -f2)
        src_id=$(sanitize_id "$source")
        tgt_id=$(sanitize_id "$target")
        echo "    ${src_id} --> ${tgt_id}"
    done <<< "$EDGES"

    echo '```'
} > "$OUTPUT"

echo "Generated $OUTPUT ($(wc -l < "$OUTPUT" | xargs) lines)"
