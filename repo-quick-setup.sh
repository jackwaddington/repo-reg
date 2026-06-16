#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAYS_BACK=30

usage() {
    cat <<'EOF'
Usage: repo-quick-setup.sh [--days <N>]

One-command setup for new machine: discovers recent repos and syncs them all.

Options:
  --days N    Look back N days instead of 30 (default)

Example:
  # Get all repos from past 30 days
  ./repo-quick-setup.sh

  # Get all repos from past 60 days
  ./repo-quick-setup.sh --days 60
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS_BACK="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                   Quick Setup: Discover & Sync Recent Repos                ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

echo "Step 1: Discovering repos from past $DAYS_BACK days..."
"$SCRIPT_DIR/repo-discover.sh" --recent --recent-days "$DAYS_BACK"

echo ""
echo "Step 2: Syncing all managed repos..."
"$SCRIPT_DIR/repo-sync.sh"

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                              ✓ All Set!                                    ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
