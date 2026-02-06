#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# provision.sh
# ------------------------------------------------------------
# - explicit, deterministic, safe re-runs
# - NEVER overwrite .env if it exists
# - Netlify site creation/linking via CLI
# - Netlify Git linkage attempted via API (NETLIFY_AUTH_TOKEN)
#   If Git provider is not authorized for the Netlify team, we WARN and continue.
# - Supabase optional; schema optional
#
# Monorepo defaults:
#   WEB_BASE_DIR    = apps/web
#   WEB_PUBLISH_DIR = dist
#   WEB_BUILD_CMD   = npm ci && npm run build
#   FUNCTIONS_DIR   = services/api/netlify/functions

CREATE_DB="false"
APPLY_SCHEMA="false"
IMPORT_ENV="false"
DEBUG="false"

GITHUB_OWNER="${GITHUB_OWNER:-ian-hunter-github}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

WEB_BASE_DIR="${WEB_BASE_DIR:-apps/web}"
WEB_PUBLISH_DIR="${WEB_PUBLISH_DIR:-dist}"
WEB_BUILD_CMD="${WEB_BUILD_CMD:-npm ci && npm run build}"
FUNCTIONS_DIR="${FUNCTIONS_DIR:-services/api/netlify/functions}"

usage() {
  cat <<'TXT'
Usage: ./scripts/provision.sh [options]

Options:
  --create-db, --sb-create   Create Supabase project (idempotent)
  --apply-schema             Apply SQL schema via migrations (sql/*.sql -> supabase/migrations -> db push)
  --import-env               Import .env into Netlify (opt-in)
  --debug                    Verbose debug output
  -h, --help

Env overrides:
  GITHUB_OWNER, GITHUB_BRANCH
  WEB_BASE_DIR, WEB_PUBLISH_DIR, WEB_BUILD_CMD, FUNCTIONS_DIR

Requires for Netlify Git automation:
  NETLIFY_AUTH_TOKEN
TXT
}

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

log()  { printf '[provision] %s\n' "$*"; }
dbg()  { [[ "$DEBUG" == "true" ]] && printf '[provision][debug] %s\n' "$*" >&2 || true; }
warn() { printf '[provision][warn] %s\n' "$*" >&2; }
die()  { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

[[ -f ".scaffold/meta.json" ]] || die "Not a scaffolded project (.scaffold/meta.json missing)"

need_cmd node
need_cmd netlify
need_cmd supabase
need_cmd curl
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd head
need_cmd sleep

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

json_from_stdin_get() {
  local expr="$1"
  node -e "
const fs = require('fs');
const raw = fs.readFileSync(0,'utf8').trim();
const j = raw ? JSON.parse(raw) : {};
const v = (function(){ return $expr; })();
if (v === undefined || v === null) process.exit(1);
process.stdout.write(String(v));
"
}

require_netlify_token() {
  if [[ -z "${NETLIFY_AUTH_TOKEN:-}" ]]; then
    warn "NETLIFY_AUTH_TOKEN not set; Netlify GitHub linking automation will be skipped."
    return 1
  fi
  return 0
}

# ----------------------------
# Netlify API helpers
# ----------------------------
netlify_api_request() {
  local method="$1"
  local url="$2"
  local data_file="${3:-}" # optional

  local body_file err_file
  body_file="$(mktemp)"
  err_file="$(mktemp)"

  local curl_args=(
    --http1.1
    -sS
    -X "$method"
    -H "Authorization: Bearer ${NETLIFY_AUTH_TOKEN}"
    -H "Content-Type: application/json"
    -o "$body_file"
    -w "%{http_code}"
  )

  if [[ -n "$data_file" ]]; then
    curl_args+=(--data-binary "@${data_file}")
  fi

  local code rc
  set +e
  code="$(curl "${curl_args[@]}" "$url" 2>"$err_file")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    if grep -qiE 'curl: \(35\)|unexpected eof' "$err_file"; then
      dbg "curl transient TLS error; retrying once..."
      : > "$err_file"
      set +e
      code="$(curl "${curl_args[@]}" "$url" 2>"$err_file")"
      rc=$?
      set -e
    fi
  fi

  if [[ $rc -ne 0 ]]; then
    printf '__HTTP_CODE__:000\n'
    sed 's/^/[provision][curl] /' "$err_file" >&2 || true
    rm -f "$body_file" "$err_file" || true
    return 1
  fi

  code="$(printf '%s' "$code" | tr -d '\r\n')"
  [[ -n "$code" ]] || code="000"

  printf '__HTTP_CODE__:%s\n' "$code"
  cat "$body_file"

  rm -f "$body_file" "$err_file" || true
  return 0
}

netlify_api_get_site() {
  local site_id="$1"
  netlify_api_request "GET" "https://api.netlify.com/api/v1/sites/${site_id}"
}

netlify_api_patch_site() {
  local site_id="$1"
  local payload_file="$2"
  netlify_api_request "PATCH" "https://api.netlify.com/api/v1/sites/${site_id}" "$payload_file"
}

parse_netlify_response() {
  local resp="$1"
  NETLIFY_HTTP_CODE="$(printf '%s\n' "$resp" | head -n 1 | sed 's/^__HTTP_CODE__://')"
  NETLIFY_HTTP_BODY="$(printf '%s\n' "$resp" | tail -n +2)"
}

# ----------------------------
# Supabase helpers
# ----------------------------
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
        if (name == want && ref != "") { print ref; exit 0 }
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

ensure_env_file_exists() {
  if [[ -f ".env" ]]; then
    dbg ".env exists; not overwriting"
    return 0
  fi

  log "Creating .env (will not overwrite if it already exists)"
  cat > .env <<'EOF'
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
VITE_SUPABASE_URL=
VITE_SUPABASE_ANON_KEY=
EOF
}

set_env_var_in_file() {
  local key="$1" value="$2" file="$3"
  [[ -f "$file" ]] || die "set_env_var_in_file: missing file: $file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#g" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# ----------------------------
# meta (informational)
# ----------------------------
MODE="$(json_file_get ".scaffold/meta.json" "j.mode || 'monorepo'")"
DB="$(json_file_get ".scaffold/meta.json" "j.db || 'none'")"

log "Mode: $MODE"
log "DB:   $DB"

# ----------------------------
# validate structure
# ----------------------------
[[ -d "$WEB_BASE_DIR" ]] || die "Expected web base dir missing: $WEB_BASE_DIR"
[[ -f "$WEB_BASE_DIR/package.json" ]] || die "Expected $WEB_BASE_DIR/package.json missing"
[[ -f "netlify.toml" ]] || die "netlify.toml missing at repo root"
[[ -d "$FUNCTIONS_DIR" ]] || warn "Functions dir not found (OK if not scaffolded yet): $FUNCTIONS_DIR"

# ----------------------------
# Netlify site create/link
# ----------------------------
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

# ----------------------------
# Netlify Git linkage (best effort)
# ----------------------------
PROJECT_NAME="$(basename "$REPO_ROOT")"
EXPECTED_REPO_PATH="${GITHUB_OWNER}/${PROJECT_NAME}"

log "Netlify: checking Git linkage (expected: ${EXPECTED_REPO_PATH} @ ${GITHUB_BRANCH})"

GIT_LINKED="false"
ADMIN_URL=""

if require_netlify_token; then
  resp="$(netlify_api_get_site "$SITE_ID" || true)"
  parse_netlify_response "$resp"
  SITE_JSON="$NETLIFY_HTTP_BODY"

  if [[ "$NETLIFY_HTTP_CODE" == "401" || "$NETLIFY_HTTP_CODE" == "403" ]]; then
    warn "Netlify API auth failed (HTTP ${NETLIFY_HTTP_CODE}). Skipping Git linkage automation."
  elif [[ "$NETLIFY_HTTP_CODE" =~ ^2 ]]; then
    # pick up admin_url
    if ADMIN_URL="$(printf '%s' "$SITE_JSON" | json_from_stdin_get "j.admin_url")" >/dev/null 2>&1; then :; else ADMIN_URL=""; fi

    LINKED_REPO_PATH=""
    LINKED_PROVIDER=""
    if LINKED_REPO_PATH="$(printf '%s' "$SITE_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.repo_path")" >/dev/null 2>&1; then :; else LINKED_REPO_PATH=""; fi
    if LINKED_PROVIDER="$(printf '%s' "$SITE_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.provider")" >/dev/null 2>&1; then :; else LINKED_PROVIDER=""; fi

    if [[ -n "$LINKED_REPO_PATH" || -n "$LINKED_PROVIDER" ]]; then
      GIT_LINKED="true"
      if [[ -n "$LINKED_REPO_PATH" && "$LINKED_REPO_PATH" != "$EXPECTED_REPO_PATH" ]]; then
        warn "Netlify site already linked to a different repo: $LINKED_REPO_PATH"
      else
        warn "Netlify site already linked to Git."
      fi
      [[ -n "$LINKED_PROVIDER"  ]] && warn "Linked provider: $LINKED_PROVIDER"
      [[ -n "$LINKED_REPO_PATH" ]] && warn "Linked repo_path: $LINKED_REPO_PATH"
    else
      log "Netlify: site not Git-linked — attempting to link to GitHub repo: $EXPECTED_REPO_PATH"

      tmp_payload="$(mktemp)"
      cat > "$tmp_payload" <<EOF
{
  "build_settings": {
    "provider": "github",
    "repo_path": "${EXPECTED_REPO_PATH}",
    "repo_branch": "${GITHUB_BRANCH}",
    "dir": "${WEB_BASE_DIR}",
    "functions_dir": "${FUNCTIONS_DIR}",
    "cmd": "${WEB_BUILD_CMD}",
    "allowed_branches": ["${GITHUB_BRANCH}"]
  }
}
EOF

      resp="$(netlify_api_patch_site "$SITE_ID" "$tmp_payload" || true)"
      rm -f "$tmp_payload" || true
      parse_netlify_response "$resp"
      PATCH_JSON="$NETLIFY_HTTP_BODY"

      if [[ "$NETLIFY_HTTP_CODE" =~ ^2 ]]; then
        # verify
        resp="$(netlify_api_get_site "$SITE_ID" || true)"
        parse_netlify_response "$resp"
        VERIFY_JSON="$NETLIFY_HTTP_BODY"

        NEW_PATH=""
        NEW_PROVIDER=""
        if NEW_PATH="$(printf '%s' "$VERIFY_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.repo_path")" >/dev/null 2>&1; then :; else NEW_PATH=""; fi
        if NEW_PROVIDER="$(printf '%s' "$VERIFY_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.provider")" >/dev/null 2>&1; then :; else NEW_PROVIDER=""; fi
        if ADMIN_URL="$(printf '%s' "$VERIFY_JSON" | json_from_stdin_get "j.admin_url")" >/dev/null 2>&1; then :; else ADMIN_URL="$ADMIN_URL"; fi

        if [[ -n "$NEW_PATH" && -n "$NEW_PROVIDER" ]]; then
          GIT_LINKED="true"
          log "Netlify: linked to GitHub repo_path: $NEW_PATH"
        else
          warn "Netlify API returned success, but Git provider fields are still empty (provider/repo_path)."
          warn "This usually means the Netlify team hasn't authorized the GitHub provider yet."
        fi
      else
        warn "Netlify API PATCH returned HTTP ${NETLIFY_HTTP_CODE}; skipping Git linkage automation."
        printf '%s\n' "$PATCH_JSON" | head -c 800 >&2 || true
      fi
    fi
  else
    warn "Netlify API GET returned HTTP ${NETLIFY_HTTP_CODE}; skipping Git linkage automation."
  fi
fi

if [[ "$GIT_LINKED" != "true" ]]; then
  warn "Git auto-deploy is NOT configured yet."
  if [[ -n "$ADMIN_URL" ]]; then
    warn "Open: $ADMIN_URL"
  else
    warn "Open: https://app.netlify.com (find site: $(basename "$REPO_ROOT"))"
  fi
  warn "Then: Site configuration → Build & deploy → Continuous deployment → Link site to Git → GitHub"
  warn "Select repo: $EXPECTED_REPO_PATH (branch: $GITHUB_BRANCH)"
fi

# ----------------------------
# If no DB configured, we're done
# ----------------------------
if [[ "$DB" != "supabase" ]]; then
  log "DB=none, skipping Supabase"
  log "Provision complete"
  exit 0
fi

# ----------------------------
# Supabase config
# ----------------------------
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

ensure_env_file_exists

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

log "Resolving Supabase project ref for name: $SB_NAME"

PROJECT_REF=""
ATTEMPTS=12
SLEEP_SECS=5

for ((i=1; i<=ATTEMPTS; i++)); do
  dbg "SB resolve attempt $i/$ATTEMPTS"
  if [[ "$DEBUG" == "true" ]]; then
    dbg "Parsed projects (first 20):"
    debug_dump_sb_projects_parsed 20 | sed 's/^/[provision][debug]   /' >&2 || true
  fi

  PROJECT_REF="$(resolve_sb_project_ref_table "$SB_NAME")"
  dbg "PROJECT_REF='${PROJECT_REF:-}'"

  [[ -n "${PROJECT_REF:-}" ]] && break
  log "Project not visible yet (attempt $i/$ATTEMPTS). Sleeping ${SLEEP_SECS}s..."
  sleep "$SLEEP_SECS"
done

[[ -n "${PROJECT_REF:-}" ]] || die "Could not resolve Supabase project ref for name: $SB_NAME"
log "Supabase project ref: $PROJECT_REF"

supabase link --project-ref "$PROJECT_REF" >/dev/null 2>&1 || true

API_URL="https://${PROJECT_REF}.supabase.co"
set_env_var_in_file "SUPABASE_URL" "$API_URL" ".env"
set_env_var_in_file "VITE_SUPABASE_URL" "$API_URL" ".env"

if grep -qE '^SUPABASE_URL=https://.*\.supabase\.com' .env; then
  die "SUPABASE_URL must end with .supabase.co (not .supabase.com). Fix .env and rerun."
fi

if [[ "$IMPORT_ENV" == "true" ]]; then
  log "Importing .env into Netlify (opt-in)"
  netlify env:import .env
else
  log "Skipping Netlify env import (default)."
fi

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

log "Provision complete"
log "Netlify siteId: $SITE_ID"
log "Git expected:   $EXPECTED_REPO_PATH ($GITHUB_BRANCH)"
log "Supabase ref:   $PROJECT_REF"
log "Env file:       $REPO_ROOT/.env"
log "Next:"
log "  1) Paste SUPABASE_SERVICE_ROLE_KEY into .env (if not already set)"
log "  2) Run locally: netlify dev"
