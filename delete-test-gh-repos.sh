#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/Projects/Tests"
OWNER="ian-hunter-github"
EXECUTE=true   # set true to actually delete

if [[ ! -d "$BASE_DIR" ]]; then
  echo "Base directory not found: $BASE_DIR" >&2
  exit 1
fi

echo "# GitHub owner: $OWNER"
echo "# Scanning: $BASE_DIR/test-*"
echo "# EXECUTE=$EXECUTE"
echo

for dir in "$BASE_DIR"/test-*; do
  [[ -d "$dir" ]] || continue

  repo="$(basename "$dir")"
  full_repo="$OWNER/$repo"

  if gh repo view "$full_repo" >/dev/null 2>&1; then
    echo "# Repo exists: $full_repo"
    if $EXECUTE; then
      gh repo delete "$full_repo" --yes
    else
      echo "gh repo delete $full_repo --yes"
    fi
  else
    echo "# Repo not found on GitHub: $full_repo (skipping)"
  fi

  echo
done
