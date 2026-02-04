#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# provision.sh
# ------------------------------------------------------------
# Philosophy:
# - explicit, deterministic, safe re-runs
# - no jq required
# - Supabase org_id is constant (from supabase.config.json)
# - NEVER overwrite .env if it exists
# - Fail loudly if required state is missing
#
# Key fixes:
# - Supabase CLI sometimes prints valid table output but exits non-zero.
#   With `set -euo pipefail`, that would abort the script.
#   We wrap `supabase projects list` with `|| true` so parsing always proceeds.
#
# Notes:
# - Netlify CLI is currently unstable in your environment; env import is opt-in.
# - This script supports both "single" and "monorepo" modes, but expects:
#     repo root netlify.toml
#     functions in services/api/netlify/functions
#     sql/*.sql at repo root (advanced example)

CREATE_DB="false"
APPLY_SCHEMA="false"
IMPORT_ENV="false"
DEBUG="false"

usage() {
  cat <<'TXT'
Usage: ./scripts/provision.sh [options]

Options:
  --create-db, --sb-create   Create Supabase project (idempotent)
  --apply-schema             Apply SQL schema via migrations (sql/*.sql -> supabase/migrations -> db push)
  --import-env               Import .env into Netlify (opt-in; may fail if Netlify CLI unstable)
  --debug                    Verbose debug output
  -h, --help

Examples:
  ./scripts/provision.sh --create-db --apply-schema --debug
  ./scripts/provision.sh --apply-schema
TXT
}

# -----------------------------
# args (strict)
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-db|--sb-create) CREATE_DB="true"; shift ;;
    --apply-schema)         APPLY_SCHEMA="true"; shift ;;
    --import-env)           IMPORT_ENV="true"; shift ;;
    --debug)                DEBUG="true"; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "[provision] ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[provision] %s\n' "$*"; }
dbg() { [[ "$DEBUG" == "true" ]] && printf '[provision][debug] %s\n' "$*" >&2 || true; }
die() { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# -----------------------------
# repo root
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

[[ -f ".scaffold/meta.json" ]] || die "Not a scaffolded project (.scaffold/meta.json missing)"

need_cmd node
need_cmd netlify
need_cmd supabase

dbg "Repo root: $REPO_ROOT"

# -----------------------------
# helpers
# -----------------------------
json_file_get() {
  local file="$1"
  local expr="$2"
  [[ -f "$file" ]] || die "Missing JSON file: $file"
  node -e "
const fs = require('fs');
const j = JSON.parse(fs.readFileSync('$file','utf8'));
const v = (function(){ return $expr; })();
if (v === undefined || v === null) process.exit(1);
process.stdout.write(String(v));
" || die "Failed reading $file ($expr)"
}

# Supabase ref resolver:
# - Parses the TABLE output of `supabase projects list` (robust vs JSON chatter)
# - IMPORTANT: Supabase CLI may exit non-zero even though it prints valid table output
#   (e.g., 'Cannot find project ref. Have you run supabase link?').
#   With pipefail, that would abort the script.
#   So we wrap the command with `|| true` and parse its output regardless.
resolve_sb_project_ref_table() {
  local want_name="$1"
  { supabase projects list 2>&1 || true; } \
    | awk -F'|' -v want="$want_name" '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

      index($0,"|")==0 { next }
      $0 ~ /REFERENCE ID|CREATED AT|ORG ID|LINKED/ { next }
      $0 ~ /^[[:space:]]*-{2,}/ { next }

      {
        ref  = trim($3)
        name = trim($4)

        if (name == want && ref != "") {
          print ref
          exit 0
        }
      }
      END { exit 0 }
    '
}

debug_dump_sb_projects_parsed() {
  local max_lines="${1:-20}"
  { supabase projects list 2>&1 || true; } \
    | awk -F'|' '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      index($0,"|")==0 { next }
      $0 ~ /REFERENCE ID|CREATED AT|ORG ID|LINKED/ { next }
      $0 ~ /^[[:space:]]*-{2,}/ { next }
      {
        ref=trim($3); name=trim($4); org=trim($2);
        if (ref != "" && name != "") printf "NAME=%s  REF=%s  ORG=%s\n", name, ref, org;
      }
    ' | head -n "$max_lines"
}

# Create .env if missing (never overwrite). Can be called before/after we know project ref.
ensure_env_file_exists() {
  if [[ -f ".env" ]]; then
    dbg ".env exists; not overwriting"
    return 0
  fi

  log "Creating .env (will not overwrite if it already exists)"
  cat > .env <<'EOF'
# Server-side (Netlify Functions)
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=

# Client-side (only needed if browser talks to Supabase directly; safe to leave blank if using functions only)
VITE_SUPABASE_URL=
VITE_SUPABASE_ANON_KEY=
EOF
}

set_env_var_in_file() {
  local key="$1" value="$2" file="$3"
  [[ -f "$file" ]] || die "set_env_var_in_file: missing file: $file"
  # Replace or append
  if grep -qE "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#g" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# -----------------------------
# read scaffold meta
# -----------------------------
MODE="$(json_file_get ".scaffold/meta.json" "j.mode || 'single'")"
DB="$(json_file_get ".scaffold/meta.json" "j.db || 'none'")"

log "Mode: $MODE"
log "DB:   $DB"

# -----------------------------
# Netlify: ensure site exists & linked
# -----------------------------
log "Netlify: ensuring site exists and is linked"

if [[ ! -f ".netlify/state.json" ]]; then
  SITE_NAME="$(basename "$REPO_ROOT")"
  log "Netlify site not linked; creating site: $SITE_NAME"
  netlify sites:create --name "$SITE_NAME"
fi

[[ -f ".netlify/state.json" ]] || die "Netlify linking failed (.netlify/state.json missing)"

SITE_ID="$(json_file_get ".netlify/state.json" "j.siteId")"
[[ -n "$SITE_ID" ]] || die "Could not determine Netlify siteId from .netlify/state.json"
log "Netlify siteId: $SITE_ID"

[[ -f "netlify.toml" ]] || die "netlify.toml missing at repo root"

# If no DB configured, we're done
if [[ "$DB" != "supabase" ]]; then
  log "DB=none, skipping Supabase"
  log "Provision complete"
  exit 0
fi

# -----------------------------
# Supabase config
# -----------------------------
[[ -f "supabase.config.json" ]] || die "Missing supabase.config.json"

SB_ORG_ID="$(json_file_get "supabase.config.json" "j.project && j.project.org_id")"
SB_REGION="$(json_file_get "supabase.config.json" "j.project && j.project.region")"
SB_NAME="$(json_file_get "supabase.config.json" "j.project && j.project.name")"

[[ -n "$SB_ORG_ID" ]] || die "supabase.config.json missing project.org_id"
[[ -n "$SB_REGION" ]] || die "supabase.config.json missing project.region"
[[ -n "$SB_NAME" ]] || die "supabase.config.json missing project.name"

log "Supabase org_id:  $SB_ORG_ID"
log "Supabase region:  $SB_REGION"
log "Supabase project: $SB_NAME"

# Ensure .env exists early so you never end up without one (never overwrite)
ensure_env_file_exists

# -----------------------------
# Create DB (optional) - idempotent
# -----------------------------
if [[ "$CREATE_DB" == "true" ]]; then
  log "Creating Supabase project (idempotent)"
  read -srp "Enter Supabase DB password (won't be stored): " DB_PASS
  echo
  [[ -n "${DB_PASS:-}" ]] || die "DB password cannot be empty"

  set +e
  CREATE_OUT="$(supabase projects create "$SB_NAME" \
    --org-id "$SB_ORG_ID" \
    --region "$SB_REGION" \
    --db-password "$DB_PASS" 2>&1)"
  CREATE_RC=$?
  set -e

  if [[ $CREATE_RC -eq 0 ]]; then
    log "Supabase project created"
  else
    if echo "$CREATE_OUT" | grep -qi 'already exists in your organization'; then
      log "Supabase project already exists (OK)"
    else
      log "Supabase projects create failed:"
      printf '%s\n' "$CREATE_OUT" | sed 's/^/[provision]   /' >&2
      die "Supabase project creation failed"
    fi
  fi
fi

# -----------------------------
# Resolve project ref (table parse) with retry + debug
# -----------------------------
log "Resolving Supabase project ref for name: $SB_NAME"

PROJECT_REF=""
ATTEMPTS=12
SLEEP_SECS=5

for ((i=1; i<=ATTEMPTS; i++)); do
  dbg "SB resolve attempt $i/$ATTEMPTS: running 'supabase projects list' and parsing table"
  if [[ "$DEBUG" == "true" ]]; then
    dbg "Parsed projects (first 20):"
    debug_dump_sb_projects_parsed 20 | sed 's/^/[provision][debug]   /' >&2 || true
  fi

  PROJECT_REF="$(resolve_sb_project_ref_table "$SB_NAME")"
  dbg "SB resolve attempt $i: PROJECT_REF='${PROJECT_REF:-}'"

  if [[ -n "${PROJECT_REF:-}" ]]; then
    break
  fi

  log "Project not visible yet (attempt $i/$ATTEMPTS). Sleeping ${SLEEP_SECS}s..."
  sleep "$SLEEP_SECS"
done

[[ -n "${PROJECT_REF:-}" ]] || die "Could not resolve Supabase project ref for name: $SB_NAME (after ${ATTEMPTS} attempts)"
log "Supabase project ref: $PROJECT_REF"

# Link locally (idempotent). Some supabase commands require link context.
supabase link --project-ref "$PROJECT_REF" >/dev/null 2>&1 || true

# Fill .env URL values (never overwrite service role key; we just set URLs)
API_URL="https://${PROJECT_REF}.supabase.co"
set_env_var_in_file "SUPABASE_URL" "$API_URL" ".env"
set_env_var_in_file "VITE_SUPABASE_URL" "$API_URL" ".env"

# Validate URL to avoid the .supabase.com mistake
if grep -qE '^SUPABASE_URL=https://.*\.supabase\.com' .env; then
  die "SUPABASE_URL must end with .supabase.co (not .supabase.com). Fix .env and rerun."
fi

# -----------------------------
# Netlify env import (opt-in)
# -----------------------------
if [[ "$IMPORT_ENV" == "true" ]]; then
  log "Importing .env into Netlify (opt-in)"
  netlify env:import .env
else
  log "Skipping Netlify env import (default)."
fi

# -----------------------------
# Apply schema (sql/*.sql -> migrations -> db push)
# -----------------------------
if [[ "$APPLY_SCHEMA" == "true" ]]; then
  log "Applying SQL schema via migrations"
  [[ -d "sql" ]] || die "sql/ directory missing at repo root"

  mkdir -p supabase/migrations

  shopt -s nullglob
  sql_files=(sql/*.sql)
  shopt -u nullglob

  [[ "${#sql_files[@]}" -gt 0 ]] || die "No sql/*.sql files found"

  for f in "${sql_files[@]}"; do
    base="$(basename "$f")"
    if ! ls supabase/migrations/*_"$base" >/dev/null 2>&1; then
      ts="$(date -u +%Y%m%d%H%M%S)"
      mig="supabase/migrations/${ts}_${base}"
      log "Creating migration: $mig"
      cp "$f" "$mig"
      sleep 1
    else
      log "Migration for $base already exists"
    fi
  done

  log "Pushing migrations"
  supabase db push --linked --yes
fi

# -----------------------------
# Summary
# -----------------------------
log "Provision complete"
log "Netlify siteId: $SITE_ID"
log "Supabase ref:   $PROJECT_REF"
log "Env file:       $REPO_ROOT/.env"
log "Next:"
log "  1) Paste SUPABASE_SERVICE_ROLE_KEY into .env (if not already set)"
log "  2) Run locally: netlify dev"
