#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# provision.sh (fixed for Netlify team slug resolution)
# ------------------------------------------------------------
# Key fixes:
# - Netlify "team" shown in CLI may be display name, NOT account_slug.
# - Resolve account_slug via GET /api/v1/accounts, then use:
#     POST /api/v1/{account_slug}/sites
#     GET  /api/v1/{account_slug}/sites?per_page=100
#
# Netlify API spec shows /{account_slug}/sites exists. :contentReference[oaicite:1]{index=1}

CREATE_DB="false"
APPLY_SCHEMA="false"
IMPORT_ENV="false"
DEBUG="false"

# ----------------------------
# Opinionated defaults
# ----------------------------
NETLIFY_TEAM_NAME="strong50plus"          # Display name (we resolve slug from this)
GITHUB_OWNER="${GITHUB_OWNER:-ian-hunter-github}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

WEB_BASE_DIR="${WEB_BASE_DIR:-apps/web}"
WEB_PUBLISH_DIR="${WEB_PUBLISH_DIR:-dist}"
WEB_BUILD_CMD="${WEB_BUILD_CMD:-npm ci && npm run build}"
FUNCTIONS_DIR="${FUNCTIONS_DIR:-services/api/netlify/functions}"

SUPABASE_DB_PASSWORD="${SUPABASE_DB_PASSWORD:-}"

usage() {
  cat <<'TXT'
Usage: ./scripts/provision.sh [options]

Options:
  --create-db, --sb-create   Create Supabase project (idempotent)
  --apply-schema             Apply SQL schema via migrations (sql/*.sql -> supabase/migrations -> db push)
  --import-env               Import .env into Netlify (opt-in)
  --debug                    Verbose debug output
  -h, --help

Env:
  NETLIFY_AUTH_TOKEN         Required for non-interactive Netlify provisioning
  SUPABASE_DB_PASSWORD       Required only if --create-db and db=supabase

Optional overrides:
  NETLIFY_TEAM_NAME
  GITHUB_OWNER, GITHUB_BRANCH
  WEB_BASE_DIR, WEB_PUBLISH_DIR, WEB_BUILD_CMD, FUNCTIONS_DIR
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
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd head
need_cmd sleep
need_cmd mkdir
need_cmd cp
need_cmd ls
need_cmd date

# Preflight: Node 18+ for global fetch
NODE_MAJOR="$(node -p "process.versions.node.split('.')[0]")"
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  die "Node >= 18 required (global fetch). Current: $(node -v)."
fi

# ----------------------------
# JSON helpers (node; no jq)
# ----------------------------
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

# ----------------------------
# Read scaffold meta
# ----------------------------
MODE="$(json_file_get ".scaffold/meta.json" "j.mode || 'single'")"
DB="$(json_file_get ".scaffold/meta.json" "j.db || 'none'")"
log "Mode: $MODE"
log "DB:   $DB"

# ----------------------------
# Netlify API via Node fetch (NOT curl)
# ----------------------------
require_netlify_token() {
  [[ -n "${NETLIFY_AUTH_TOKEN:-}" ]] || die "NETLIFY_AUTH_TOKEN not set (required for non-interactive Netlify provisioning)."
}

# Prints:
#   __HTTP_CODE__:XYZ
#   <body text>
netlify_api_request() {
  local method="$1"
  local url="$2"
  local data_file="${3:-}"

  require_netlify_token

  local body=""
  if [[ -n "$data_file" ]]; then
    [[ -f "$data_file" ]] || die "Netlify API payload file missing: $data_file"
    body="$(cat "$data_file")"
  fi

  __NETLIFY_BODY__="$body" node - "$method" "$url" <<'NODE'
const method = process.argv[2];
const url = process.argv[3];
const token = process.env.NETLIFY_AUTH_TOKEN;
const body = process.env.__NETLIFY_BODY__ || "";

(async () => {
  try {
    const res = await fetch(url, {
      method,
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: body ? body : undefined,
    });

    const text = await res.text();
    process.stdout.write(`__HTTP_CODE__:${res.status}\n`);
    process.stdout.write(text);
  } catch (e) {
    process.stdout.write(`__HTTP_CODE__:000\n`);
    console.error("[provision][node-fetch] " + (e?.message || String(e)));
    process.exit(1);
  }
})();
NODE
}

parse_netlify_response() {
  local resp="$1"
  NETLIFY_HTTP_CODE="$(printf '%s\n' "$resp" | head -n 1 | sed 's/^__HTTP_CODE__://')"
  NETLIFY_HTTP_BODY="$(printf '%s\n' "$resp" | tail -n +2)"
}

# ----------------------------
# Netlify endpoints
# ----------------------------
netlify_api_get_site() {
  local site_id="$1"
  netlify_api_request "GET" "https://api.netlify.com/api/v1/sites/${site_id}"
}

netlify_api_list_accounts() {
  netlify_api_request "GET" "https://api.netlify.com/api/v1/accounts"
}

netlify_resolve_account_slug() {
  # Resolve account_slug from NETLIFY_TEAM_NAME (match by name OR slug)
  local want="$1"

  local resp
  resp="$(netlify_api_list_accounts || true)"
  parse_netlify_response "$resp"
  if [[ ! "$NETLIFY_HTTP_CODE" =~ ^2 ]]; then
    warn "Netlify API /accounts returned HTTP ${NETLIFY_HTTP_CODE}"
    printf '%s\n' "$NETLIFY_HTTP_BODY" | head -c 800 >&2 || true
    return 1
  fi

  printf '%s' "$NETLIFY_HTTP_BODY" | node -e "
const fs=require('fs');
const arr=JSON.parse(fs.readFileSync(0,'utf8'));
const want='${want}';
const hit=arr.find(a => (a && (a.slug===want || a.name===want)));
process.stdout.write(hit?.slug ? String(hit.slug) : '');
"
}

netlify_api_list_team_sites() {
  local account_slug="$1"
  netlify_api_request "GET" "https://api.netlify.com/api/v1/${account_slug}/sites?per_page=100"
}

netlify_find_site_id_by_name() {
  local account_slug="$1"
  local want_name="$2"

  local resp
  resp="$(netlify_api_list_team_sites "$account_slug" || true)"
  parse_netlify_response "$resp"
  [[ "$NETLIFY_HTTP_CODE" =~ ^2 ]] || return 1

  printf '%s' "$NETLIFY_HTTP_BODY" | node -e "
const fs=require('fs');
const arr=JSON.parse(fs.readFileSync(0,'utf8'));
const hit=arr.find(s => s && s.name==='${want_name}');
process.stdout.write(hit?.id ? String(hit.id) : '');
"
}

netlify_api_create_site_in_team_strict() {
  local account_slug="$1"
  local name="$2"

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
{
  "name": "${name}"
}
EOF

  local resp
  resp="$(netlify_api_request "POST" "https://api.netlify.com/api/v1/${account_slug}/sites" "$tmp" || true)"
  rm -f "$tmp" || true

  parse_netlify_response "$resp"

  if [[ "$NETLIFY_HTTP_CODE" =~ ^2 ]]; then
    printf '%s' "$NETLIFY_HTTP_BODY"
    return 0
  fi

  warn "Netlify site create failed (HTTP ${NETLIFY_HTTP_CODE}). Response body:"
  printf '%s\n' "$NETLIFY_HTTP_BODY" | head -c 1200 >&2 || true
  return 1
}

# ----------------------------
# Netlify: ensure site exists & linked locally (NO PROMPTS)
# ----------------------------
log "Netlify: ensuring site exists and is linked"

SITE_NAME="$(basename "$REPO_ROOT")"
EXPECTED_REPO_PATH="${GITHUB_OWNER}/${SITE_NAME}"

ACCOUNT_SLUG="$(netlify_resolve_account_slug "${NETLIFY_TEAM_NAME}" || true)"
if [[ -z "$ACCOUNT_SLUG" ]]; then
  die "Could not resolve Netlify account slug for team '${NETLIFY_TEAM_NAME}'. Check Team Settings → Team slug in Netlify UI."
fi
dbg "Resolved Netlify account_slug: $ACCOUNT_SLUG"

if [[ -f ".netlify/state.json" ]]; then
  EXISTING_SITE_ID="$(json_file_get ".netlify/state.json" "j.siteId")"
  [[ -n "$EXISTING_SITE_ID" ]] || die ".netlify/state.json exists but siteId is empty. Delete .netlify/ and rerun."
fi

if [[ ! -f ".netlify/state.json" ]]; then
  log "Netlify site not linked; ensuring site exists in team=${NETLIFY_TEAM_NAME} (slug=${ACCOUNT_SLUG}) with name=${SITE_NAME}"

  EXISTING_ID="$(netlify_find_site_id_by_name "$ACCOUNT_SLUG" "$SITE_NAME" || true)"
  if [[ -n "$EXISTING_ID" ]]; then
    log "Netlify: site already exists (reusing): $SITE_NAME (id=$EXISTING_ID)"
    netlify link --id "$EXISTING_ID" >/dev/null
  else
    log "Netlify: creating site via API in team: $SITE_NAME"
    site_json="$(netlify_api_create_site_in_team_strict "$ACCOUNT_SLUG" "$SITE_NAME")" \
      || die "Failed to create Netlify site with required name '${SITE_NAME}'."

    SITE_ID_CREATED="$(printf '%s' "$site_json" | json_from_stdin_get "j.id || j.site_id")"
    [[ -n "$SITE_ID_CREATED" ]] || die "Created Netlify site but could not parse site id."
    netlify link --id "$SITE_ID_CREATED" >/dev/null
  fi
fi

[[ -f ".netlify/state.json" ]] || die "Netlify linking failed (.netlify/state.json missing)"
SITE_ID="$(json_file_get ".netlify/state.json" "j.siteId")"
log "Netlify siteId: $SITE_ID"

# ----------------------------
# Netlify: best-effort Git linkage via API (warn if not authorized)
# ----------------------------
log "Netlify: checking Git linkage (expected: ${EXPECTED_REPO_PATH} @ ${GITHUB_BRANCH})"

resp="$(netlify_api_get_site "$SITE_ID" || true)"
parse_netlify_response "$resp"
SITE_JSON="$NETLIFY_HTTP_BODY"

if [[ "$NETLIFY_HTTP_CODE" == "401" || "$NETLIFY_HTTP_CODE" == "403" ]]; then
  warn "Netlify API auth failed (HTTP ${NETLIFY_HTTP_CODE}). Skipping Git linkage automation."
elif [[ "$NETLIFY_HTTP_CODE" =~ ^2 ]]; then
  LINKED_REPO_PATH=""
  LINKED_PROVIDER=""
  if LINKED_REPO_PATH="$(printf '%s' "$SITE_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.repo_path")" >/dev/null 2>&1; then :; else LINKED_REPO_PATH=""; fi
  if LINKED_PROVIDER="$(printf '%s' "$SITE_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.provider")" >/dev/null 2>&1; then :; else LINKED_PROVIDER=""; fi

  if [[ -n "$LINKED_REPO_PATH" || -n "$LINKED_PROVIDER" ]]; then
    warn "Netlify site already linked to Git."
    [[ -n "$LINKED_PROVIDER"  ]] && warn "Linked provider:  $LINKED_PROVIDER"
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

    patch_resp="$(netlify_api_request "PATCH" "https://api.netlify.com/api/v1/sites/${SITE_ID}" "$tmp_payload" || true)"
    rm -f "$tmp_payload" || true
    parse_netlify_response "$patch_resp"
    PATCH_BODY="$NETLIFY_HTTP_BODY"

    if [[ "$NETLIFY_HTTP_CODE" =~ ^2 ]]; then
      verify_resp="$(netlify_api_get_site "$SITE_ID" || true)"
      parse_netlify_response "$verify_resp"
      VERIFY_JSON="$NETLIFY_HTTP_BODY"

      NEW_PATH=""
      NEW_PROVIDER=""
      if NEW_PATH="$(printf '%s' "$VERIFY_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.repo_path")" >/dev/null 2>&1; then :; else NEW_PATH=""; fi
      if NEW_PROVIDER="$(printf '%s' "$VERIFY_JSON" | json_from_stdin_get "j.build_settings && j.build_settings.provider")" >/dev/null 2>&1; then :; else NEW_PROVIDER=""; fi

      if [[ -n "$NEW_PATH" && -n "$NEW_PROVIDER" ]]; then
        log "Netlify: linked to GitHub repo_path: $NEW_PATH"
      else
        warn "Netlify API returned success, but Git provider fields are still empty (provider/repo_path)."
        warn "This usually means the Netlify team hasn't authorized the GitHub provider yet."
        ADMIN_URL="$(printf '%s' "$VERIFY_JSON" | json_from_stdin_get "j.admin_url || ''" 2>/dev/null || true)"
        [[ -n "$ADMIN_URL" ]] && warn "Open: $ADMIN_URL"
        warn "Then: Site configuration → Build & deploy → Continuous deployment → Link site to Git → GitHub"
        warn "Select repo: ${EXPECTED_REPO_PATH} (branch: ${GITHUB_BRANCH})"
      fi
    else
      warn "Netlify API PATCH returned HTTP ${NETLIFY_HTTP_CODE}; skipping Git linkage automation."
      printf '%s\n' "$PATCH_BODY" | head -c 800 >&2 || true
    fi
  fi
else
  warn "Netlify API GET returned HTTP ${NETLIFY_HTTP_CODE}; skipping Git linkage automation."
fi

# ----------------------------
# Supabase (optional)
# ----------------------------
if [[ "$DB" != "supabase" ]]; then
  log "DB=none, skipping Supabase"
  log "Provision complete"
  exit 0
fi

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

if [[ ! -f ".env" ]]; then
  log "Creating .env (will not overwrite if it already exists)"
  cat > .env <<'EOF'
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
VITE_SUPABASE_URL=
VITE_SUPABASE_ANON_KEY=
EOF
fi

if [[ "$CREATE_DB" == "true" ]]; then
  [[ -n "$SUPABASE_DB_PASSWORD" ]] || die "SUPABASE_DB_PASSWORD not set (required for non-interactive Supabase project creation)"
  log "Creating Supabase project (idempotent, non-interactive)"

  set +e
  CREATE_OUT="$(supabase projects create "$SB_NAME" \
    --org-id "$SB_ORG_ID" \
    --region "$SB_REGION" \
    --db-password "$SUPABASE_DB_PASSWORD" 2>&1)"
  CREATE_RC=$?
  set -e

  if [[ $CREATE_RC -eq 0 ]]; then
    log "Supabase project created"
  else
    if printf '%s' "$CREATE_OUT" | grep -qi 'already exists'; then
      log "Supabase project already exists (OK)"
    else
      printf '%s\n' "$CREATE_OUT" | sed 's/^/[provision]   /' >&2
      die "Supabase project creation failed"
    fi
  fi
fi

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

log "Resolving Supabase project ref for name: $SB_NAME"

PROJECT_REF=""
ATTEMPTS=12
SLEEP_SECS=5
for ((i=1; i<=ATTEMPTS; i++)); do
  PROJECT_REF="$(resolve_sb_project_ref_table "$SB_NAME")"
  [[ -n "$PROJECT_REF" ]] && break
  log "Project not visible yet (attempt $i/$ATTEMPTS). Sleeping ${SLEEP_SECS}s..."
  sleep "$SLEEP_SECS"
done
[[ -n "$PROJECT_REF" ]] || die "Could not resolve Supabase project ref for name: $SB_NAME"

log "Supabase project ref: $PROJECT_REF"
supabase link --project-ref "$PROJECT_REF" >/dev/null 2>&1 || true

API_URL="https://${PROJECT_REF}.supabase.co"

set_env_var_in_file() {
  local key="$1" value="$2" file="$3"
  [[ -f "$file" ]] || die "Missing file: $file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#g" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

set_env_var_in_file "SUPABASE_URL" "$API_URL" ".env"
set_env_var_in_file "VITE_SUPABASE_URL" "$API_URL" ".env"

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
