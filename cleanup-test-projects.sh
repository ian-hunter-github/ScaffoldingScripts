#!/usr/bin/env bash
set -euo pipefail

PREFIX="test-"
DRY_RUN="false"
DEBUG="false"

usage() {
  cat <<'TXT'
Usage: cleanup-tests.sh [options]

Options:
  --dry-run    Show what would be deleted, but do not delete anything
  --debug      Print the Supabase command + raw JSON, and match diagnostics
  -h, --help   Show this help

Deletes Netlify sites and Supabase projects whose NAME starts with "test-".
TXT
}

# -----------------------------
# args (strict)
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --debug)   DEBUG="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[cleanup] ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo "=============================================="
echo " DANGEROUS DEV CLEANUP SCRIPT"
echo " Target prefix : '${PREFIX}'"
echo " Dry-run mode  : ${DRY_RUN}"
echo " Debug mode    : ${DEBUG}"
echo "=============================================="
echo

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[cleanup] ERROR: missing command: $1" >&2
    exit 1
  }
}

confirm() {
  read -rp "$1 [y/N] " ans
  [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]]
}

need_cmd netlify
need_cmd supabase
need_cmd node
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd gh

delete_test_repo() {
  local NAME="$1"

  if [[ -z "$NAME" ]]; then
    echo "delete_test_repo: missing project name" >&2
    return 1
  fi

  local TESTS_DIR="${HOME}/Projects/Tests"
  local PROJECT_DIR="${TESTS_DIR}/${NAME}"

  # 1) Verify local folder exists
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "[skip] Local folder does not exist: $PROJECT_DIR" >&2
    return 1
  fi

  # 2) Verify gh is available and authenticated
  if ! command -v gh >/dev/null 2>&1; then
    echo "[error] gh CLI not installed" >&2
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "[error] gh not authenticated" >&2
    return 1
  fi

  # 3) Resolve owner from current auth context
  local OWNER
  OWNER="$(gh api user --jq .login 2>/dev/null)" || {
    echo "[error] Failed to resolve GitHub user" >&2
    return 1
  }

  local REPO="${OWNER}/${NAME}"

  # 4) Verify repo exists
  if ! gh repo view "$REPO" >/dev/null 2>&1; then
    echo "[skip] GitHub repo does not exist: $REPO"
    return 0
  fi

  # 5) Final confirmation
  echo
  echo "About to DELETE GitHub repo:"
  echo "  Local folder : $PROJECT_DIR"
  echo "  GitHub repo  : $REPO"
  read -rp "Type the repo name to confirm deletion: " CONFIRM

  if [[ "$CONFIRM" != "$NAME" ]]; then
    echo "[abort] Confirmation mismatch"
    return 1
  fi

  # 6) Delete repo
  gh repo delete "$REPO" --confirm

  echo "[ok] Deleted GitHub repo: $REPO"
}

# ------------------------------------------------------------
# Netlify cleanup (text mode)
# ------------------------------------------------------------
echo "Fetching Netlify sites…"

NETLIFY_MATCHES="$(
  netlify sites:list 2>&1 | awk -v prefix="$PREFIX" '
    match($0, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) {
      id = substr($0, RSTART, RLENGTH)
      name = $1
      if (index(name, prefix) == 1) {
        printf "%s\t%s\n", name, id
      }
    }
  '
)"

if [[ -z "${NETLIFY_MATCHES:-}" ]]; then
  echo "No Netlify sites matching '${PREFIX}*'"
else
  echo
  echo "Netlify sites matched:"
  echo "$NETLIFY_MATCHES" | sed 's/^/  - /'
  echo

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Netlify deletions skipped"
  else
    if confirm "Delete ALL Netlify sites listed above?"; then
      echo "$NETLIFY_MATCHES" | while IFS=$'\t' read -r name id; do
        [[ -n "${id:-}" ]] || continue
        echo "Deleting Netlify site: NAME='${name}' ID='${id}'"
        netlify sites:delete "$id" --force
      done
    else
      echo "Skipping Netlify deletion."
    fi
  fi
fi

# ------------------------------------------------------------
# Supabase cleanup (JSON-based, with --debug observability)
# ------------------------------------------------------------
echo
echo "Fetching Supabase projects…"

SB_CMD=(supabase projects list --output json)
echo "[cleanup] running: ${SB_CMD[*]}"

SB_RAW="$("${SB_CMD[@]}" 2>&1 || true)"

if [[ "$DEBUG" == "true" ]]; then
  echo
  echo "----- Supabase raw output (verbatim) -----"
  printf '%s\n' "$SB_RAW"
  echo "------------------------------------------"
fi

# Parse robustly:
# - find first { or [ (handles chatter)
# - trim to last } or ]
# - parse
# - match name startsWith PREFIX
# - output: name<TAB>ref
SUPABASE_MATCHES="$(
  printf '%s' "$SB_RAW" \
    | FILTER_PREFIX="$PREFIX" DEBUG="$DEBUG" node -e '
const fs = require("fs");

const raw = fs.readFileSync(0, "utf8");

// Find first JSON char anywhere
const iObj = raw.indexOf("{");
const iArr = raw.indexOf("[");
let i = -1;
if (iObj >= 0 && iArr >= 0) i = Math.min(iObj, iArr);
else i = Math.max(iObj, iArr);

if (i < 0) {
  if (process.env.DEBUG === "true") {
    console.error("[cleanup] DEBUG: no JSON start found in supabase output");
    console.error(raw.slice(0, 400));
  }
  process.exit(0);
}

let s = raw.slice(i).trim();

// Trim trailing chatter after JSON
const lastArr = s.lastIndexOf("]");
const lastObj = s.lastIndexOf("}");
const last = Math.max(lastArr, lastObj);
if (last >= 0) s = s.slice(0, last + 1).trim();

let projects;
try {
  projects = JSON.parse(s);
} catch (e) {
  if (process.env.DEBUG === "true") {
    console.error("[cleanup] DEBUG: JSON.parse failed");
    console.error(s.slice(0, 800));
  }
  process.exit(0);
}

const prefix = process.env.FILTER_PREFIX || "test-";
const debug = process.env.DEBUG === "true";

if (debug) {
  console.error(`[cleanup] DEBUG: filter prefix = "${prefix}"`);
  console.error(`[cleanup] DEBUG: projects count = ${projects.length}`);
}

let matched = 0;
for (const p of projects) {
  let name = (p && typeof p.name === "string") ? p.name : "";
  name = name.trim();

  if (!name.startsWith(prefix)) continue;

  const ref = p.ref || p.project_ref || p.id || "";
  if (!ref) continue;

  matched++;
  process.stdout.write(`${name}\t${ref}\n`);
}

if (debug) {
  console.error(`[cleanup] DEBUG: matched = ${matched}`);
}
'
)"

if [[ -z "${SUPABASE_MATCHES//[[:space:]]/}" ]]; then
  echo "No Supabase projects matching '${PREFIX}*'"
else
  # De-duplicate by ref
  SUPABASE_MATCHES="$(printf '%s\n' "$SUPABASE_MATCHES" | awk -F'\t' '!seen[$2]++')"

  echo
  echo "Supabase projects matched:"
  echo "$SUPABASE_MATCHES" | sed 's/^/  - /'
  echo

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Supabase deletions skipped"
  else
    if confirm "Delete ALL Supabase projects listed above?"; then
      echo "$SUPABASE_MATCHES" | while IFS=$'\t' read -r name ref; do
        [[ -n "${ref:-}" ]] || continue
        echo "Deleting Supabase project: NAME='${name}' REF='${ref}'"
        supabase projects delete "$ref" --yes
      done
    else
      echo "Skipping Supabase deletion."
    fi
  fi
fi

for d in "${HOME}/Projects/Tests"/test-*; do
  [[ -d "$d" ]] || continue
  delete_test_repo "$(basename "$d")"
done

echo
echo "Cleanup complete."
