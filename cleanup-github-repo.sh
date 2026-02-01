#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# cleanup-github-repo.sh
#
# Purpose:
#   - Delete the remote GitHub repository
#   - Remove the local .git directory
#   - Leave working files untouched
#
# Safety:
#   - Requires confirmation (Y/N)
#   - --force skips confirmation
#
# Usage:
#   ./cleanup-github-repo.sh
#   ./cleanup-github-repo.sh --force
#
# Requirements:
#   - git
#   - gh (GitHub CLI)
#   - gh authenticated (gh auth login)
# ------------------------------------------------------------------------------

FORCE="no"

if [[ "${1:-}" == "--force" ]]; then
  FORCE="yes"
fi

fail() { echo "❌ $1" >&2; exit 1; }
info() { echo "ℹ️  $1"; }
ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }

command -v git >/dev/null 2>&1 || fail "git not found."
command -v gh  >/dev/null 2>&1 || fail "gh (GitHub CLI) not found. Install it and run: gh auth login"

# Ensure gh is authenticated
if ! gh auth status >/dev/null 2>&1; then
  fail "GitHub CLI is not authenticated. Run: gh auth login"
fi

# Ensure we're in a git repo
if [[ ! -d ".git" ]]; then
  fail "No .git directory found. This does not appear to be a git repository."
fi

# Determine remote repo from origin
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "${ORIGIN_URL}" ]] || fail "No 'origin' remote found."

# Normalize repo slug (supports SSH and HTTPS)
if [[ "${ORIGIN_URL}" =~ github.com[:/](.+)/(.+)\.git$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  fail "Origin remote does not look like a GitHub repo: ${ORIGIN_URL}"
fi

FULL_REPO="${OWNER}/${REPO}"

echo
warn "DESTRUCTIVE OPERATION"
echo "This will:"
echo "  1) Delete the remote GitHub repo: ${FULL_REPO}"
echo "  2) Remove the local .git directory"
echo "  3) Leave all working files intact"
echo

if [[ "${FORCE}" != "yes" ]]; then
  read -r -p "Are you absolutely sure? Type 'yes' to continue: " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# Delete remote repo
# ------------------------------------------------------------------------------
info "Deleting remote GitHub repo: ${FULL_REPO}"
if gh repo view "${FULL_REPO}" >/dev/null 2>&1; then
  gh repo delete "${FULL_REPO}" --yes
  ok "Remote GitHub repo deleted."
else
  warn "Remote GitHub repo does not exist or is not accessible. Skipping."
fi

# ------------------------------------------------------------------------------
# Remove local git repo
# ------------------------------------------------------------------------------
info "Removing local .git directory..."
rm -rf .git
ok "Local git repository removed."

echo
ok "Cleanup complete."
echo "You are now back to a non-git, non-GitHub project directory."
