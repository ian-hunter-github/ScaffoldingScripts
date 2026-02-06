#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# scaffold.sh
#
# Low-magic, deterministic scaffolder.
#
# Creates a local project (idempotent by refusing to overwrite),
# and copies templates into place. Provisioning is done later by
# scripts/provision.sh (copied into the project).
#
# NEW (Git/GitHub):
# - Requires `gh` to be installed and logged in (aborts otherwise)
# - Initializes local git repo (if missing)
# - Attempts to create GitHub repo (if missing), otherwise continues
# - Commits scaffolded files locally
# - Ensures remote `origin` points to GitHub and pushes `main`
#
# Template layout (repo):
#   Scripts/
#     scaffold.sh
#     Templates/
#       base/
#         netlify.toml
#         sql/
#         services/api/netlify/functions/
#         packages/
#         package.json
#         tests/                  (optional)
#         scripts/test-api.sh     (optional)
#         supabase.config.json
#       apps/
#         web-react/
#           package.json
#           src/...
#         web-vanilla/            (optional)
#         desktop-tauri/          (placeholder)
#       provision.sh
#       check-tools.mjs
# ============================================================

# ----------------------------
# Defaults
# ----------------------------
UIS=()
EXAMPLE="minimal"
DB="none"

# GitHub defaults
# - Set GITHUB_OWNER to override (e.g. export GITHUB_OWNER="ian-hunter-github")
# - Set GITHUB_VISIBILITY to override: private|public (default private)
GITHUB_OWNER="${GITHUB_OWNER:-ian-hunter-github}"
GITHUB_VISIBILITY="${GITHUB_VISIBILITY:-private}"

# ----------------------------
# Helpers
# ----------------------------
usage() {
  cat <<'TXT'
Usage:
  scaffold.sh <project-name> [options]

Options:
  --ui web-react|web-vanilla|desktop-tauri   (repeatable)
  --example minimal|advanced
  --db none|supabase
  -h, --help

Environment:
  GITHUB_OWNER        GitHub owner/user/org (default: ian-hunter-github)
  GITHUB_VISIBILITY   private|public (default: private)

Examples:
  scaffold.sh myapp --ui web-react
  scaffold.sh myapp --ui web-react --example advanced --db supabase
  scaffold.sh myapp --ui desktop-tauri --example minimal --db none
TXT
}

log() { echo "ℹ️  $*"; }
die() { echo "❌ $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# Copy directory contents src -> dst (dst created if missing)
copy_dir_contents() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || die "Missing template dir: $src"
  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/
}

dir_is_empty_or_missing() {
  local d="$1"
  [[ ! -e "$d" ]] && return 0
  [[ -d "$d" ]] || return 1
  shopt -s dotglob nullglob
  local items=("$d"/*)
  shopt -u dotglob nullglob
  [[ ${#items[@]} -eq 0 ]]
}

# Create Vite skeleton ONLY (no install). Must be empty/missing dst.
create_vite_skeleton() {
  local dst="$1" template="$2"
  [[ -n "$dst" ]] || die "create_vite_skeleton: missing dst"
  [[ -n "$template" ]] || die "create_vite_skeleton: missing template"

  log "Creating Vite skeleton: $dst (template=$template)"

  if ! dir_is_empty_or_missing "$dst"; then
    die "Vite destination exists and is not empty (refusing to overwrite): $dst"
  fi

  mkdir -p "$(dirname "$dst")"
  rm -rf "$dst" 2>/dev/null || true

  # Deterministic / non-interactive best-effort:
  # - don't pipe stdin (can trigger 'Operation cancelled')
  # - ensure prompts are not needed by guaranteeing an empty destination
  CI=1 npm_config_yes=true npm create vite@latest "$dst" -- --template "$template" --no-install

  [[ -f "$dst/index.html" ]] || die "Vite did not create $dst/index.html (create-vite likely cancelled)"
}

overlay_ui_src() {
  local ui="$1" dst_app="$2"
  local src="$TEMPLATES_DIR/apps/$ui/src"
  [[ -d "$src" ]] || die "Missing UI template src: $src"
  [[ -d "$dst_app/src" ]] || die "Missing destination src dir: $dst_app/src"
  cp -R "$src"/. "$dst_app/src/"
}

write_meta_json() {
  local mode="$1" example="$2" db="$3"
  mkdir -p .scaffold
  # Write ui array safely
  local ui_json=""
  if [[ ${#UIS[@]} -gt 0 ]]; then
    ui_json="$(printf '"%s",' "${UIS[@]}" | sed 's/,$//')"
  fi

  cat > .scaffold/meta.json <<EOF
{
  "mode": "$mode",
  "ui": [${ui_json}],
  "example": "$example",
  "db": "$db"
}
EOF
}

require_gh_logged_in() {
  need_cmd gh
  # `gh auth status` returns non-zero when not authenticated
  gh auth status -h github.com >/dev/null 2>&1 || die "GitHub CLI not logged in. Run: gh auth login"
}

git_init_if_needed() {
  if [[ -d ".git" ]]; then
    log "Git repo already exists"
  else
    need_cmd git
    log "Initializing local git repo"
    git init >/dev/null
    # Ensure main
    git branch -M main >/dev/null 2>&1 || true
  fi
}

git_commit_scaffolded_changes() {
  # Ensure we can commit even if user has no global git identity set
  if ! git config user.name >/dev/null 2>&1; then
    git config user.name "scaffold.sh"
  fi
  if ! git config user.email >/dev/null 2>&1; then
    git config user.email "scaffold@local"
  fi

  git add -A

  # If nothing to commit, don't fail the script
  if git diff --cached --quiet; then
    log "No changes to commit"
    return 0
  fi

  log "Committing scaffolded files"
  git commit -m "Initial scaffold" >/dev/null
}

ensure_github_repo_and_push() {
  local owner="$1" repo="$2"
  local full_repo="${owner}/${repo}"

  # Validate visibility
  case "$GITHUB_VISIBILITY" in
    private|public) ;;
    *) die "Invalid GITHUB_VISIBILITY: $GITHUB_VISIBILITY (use private|public)" ;;
  esac

  log "Ensuring GitHub repo exists: $full_repo"

  if gh repo view "$full_repo" >/dev/null 2>&1; then
    log "GitHub repo already exists: $full_repo"
  else
    log "Creating GitHub repo: $full_repo ($GITHUB_VISIBILITY)"
    # Create without prompts
    if [[ "$GITHUB_VISIBILITY" == "private" ]]; then
      gh repo create "$full_repo" --private >/dev/null
    else
      gh repo create "$full_repo" --public >/dev/null
    fi
  fi

  # Ensure origin remote is set correctly
  local origin_url="https://github.com/${full_repo}.git"

  if git remote get-url origin >/dev/null 2>&1; then
    # If origin exists but is different, make it deterministic by setting it
    local current
    current="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$current" != "$origin_url" && "$current" != "git@github.com:${full_repo}.git" ]]; then
      log "Updating origin remote -> $origin_url"
      git remote set-url origin "$origin_url"
    else
      log "Origin remote already set"
    fi
  else
    log "Adding origin remote -> $origin_url"
    git remote add origin "$origin_url"
  fi

  # Ensure branch name is main
  git branch -M main >/dev/null 2>&1 || true

  # Push (set upstream). If no commits exist, push would fail; we commit earlier.
  log "Pushing main -> origin (set upstream)"
  git push -u origin main >/dev/null
}

# ----------------------------
# Args
# ----------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }
PROJECT="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui)
      [[ $# -ge 2 ]] || die "--ui requires a value"
      UIS+=("$2")
      shift 2
      ;;
    --example)
      [[ $# -ge 2 ]] || die "--example requires a value"
      EXAMPLE="$2"
      shift 2
      ;;
    --db)
      [[ $# -ge 2 ]] || die "--db requires a value"
      DB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# ----------------------------
# Validate
# ----------------------------
[[ "${#UIS[@]}" -gt 0 ]] || die "At least one --ui is required"

case "$EXAMPLE" in
  minimal|advanced) ;;
  *) die "Invalid --example: $EXAMPLE" ;;
esac

case "$DB" in
  none|supabase) ;;
  *) die "Invalid --db: $DB" ;;
esac

# Only allow one web UI (web-react OR web-vanilla), but desktop-tauri can combine.
web_count=0
for ui in "${UIS[@]}"; do
  case "$ui" in
    web-react|web-vanilla) web_count=$((web_count+1)) ;;
    desktop-tauri) ;;
    *) die "Unknown UI: $ui" ;;
  esac
done
[[ "$web_count" -le 1 ]] || die "Only one web UI is allowed (choose web-react OR web-vanilla)"

[[ ! -e "$PROJECT" ]] || die "Path already exists: $PROJECT"

MODE="single"
[[ "${#UIS[@]}" -gt 1 ]] && MODE="monorepo"

# ----------------------------
# Locate Templates (relative to this script)
# ----------------------------
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPTS_DIR/Templates"

[[ -d "$TEMPLATES_DIR" ]] || die "Templates directory missing: $TEMPLATES_DIR"
[[ -f "$TEMPLATES_DIR/provision.sh" ]] || die "Missing template: $TEMPLATES_DIR/provision.sh"
[[ -f "$TEMPLATES_DIR/check-tools.mjs" ]] || die "Missing template: $TEMPLATES_DIR/check-tools.mjs"
[[ -f "$TEMPLATES_DIR/base/netlify.toml" ]] || die "Missing template: $TEMPLATES_DIR/base/netlify.toml"

need_cmd node
need_cmd npm
need_cmd git

# GitHub CLI must exist and be logged in (abort otherwise)
require_gh_logged_in

# ----------------------------
# Create project folder
# ----------------------------
mkdir -p "$PROJECT"
cd "$PROJECT"

write_meta_json "$MODE" "$EXAMPLE" "$DB"

# Copy core scripts into project
mkdir -p scripts
cp "$TEMPLATES_DIR/provision.sh" scripts/provision.sh
cp "$TEMPLATES_DIR/check-tools.mjs" scripts/check-tools.mjs
chmod +x scripts/provision.sh || true

# netlify.toml at root of project
cp "$TEMPLATES_DIR/base/netlify.toml" netlify.toml

# ----------------------------
# Advanced base templates
# ----------------------------
if [[ "$EXAMPLE" == "advanced" ]]; then
  log "Applying base templates (advanced)"

  [[ -d "$TEMPLATES_DIR/base/sql" ]]      || die "Missing template dir: $TEMPLATES_DIR/base/sql"
  [[ -d "$TEMPLATES_DIR/base/services" ]] || die "Missing template dir: $TEMPLATES_DIR/base/services"
  [[ -d "$TEMPLATES_DIR/base/packages" ]] || die "Missing template dir: $TEMPLATES_DIR/base/packages"

  copy_dir_contents "$TEMPLATES_DIR/base/sql"      "sql"
  copy_dir_contents "$TEMPLATES_DIR/base/services" "services"
  copy_dir_contents "$TEMPLATES_DIR/base/packages" "packages"

  # Copy template tests (optional)
  if [[ -d "$TEMPLATES_DIR/base/tests" ]]; then
    log "Copying template tests -> tests/"
    copy_dir_contents "$TEMPLATES_DIR/base/tests" "tests"
  else
    log "No template tests directory found at $TEMPLATES_DIR/base/tests (skipping)"
  fi

  # Copy optional test runner into project scripts/
  if [[ -f "$TEMPLATES_DIR/base/scripts/test-api.sh" ]]; then
    log "Copying test runner -> scripts/test-api.sh"
    cp "$TEMPLATES_DIR/base/scripts/test-api.sh" scripts/test-api.sh
    chmod +x scripts/test-api.sh || true
  fi

  # Copy optional dev runner into project scripts/
  if [[ -f "$TEMPLATES_DIR/base/scripts/dev.sh" ]]; then
    log "Copying dev runner -> scripts/dev.sh"
    cp "$TEMPLATES_DIR/base/scripts/dev.sh" scripts/dev.sh
    chmod +x scripts/dev.sh || true
  fi

  # Root package.json (optional but recommended for advanced)
  if [[ -f "$TEMPLATES_DIR/base/package.json" ]]; then
    cp "$TEMPLATES_DIR/base/package.json" package.json
    npm install
  fi
fi

# DB config template at project root if supabase
if [[ "$DB" == "supabase" ]]; then
  [[ -f "$TEMPLATES_DIR/base/supabase.config.json" ]] || die "Missing template: $TEMPLATES_DIR/base/supabase.config.json"
  sed "s/__PROJECT_NAME__/${PROJECT}/g" \
    "$TEMPLATES_DIR/base/supabase.config.json" > supabase.config.json
fi

# ----------------------------
# UI targets
# ----------------------------
for ui in "${UIS[@]}"; do
  case "$ui" in
    web-react)
      log "Scaffolding Vite app (react-ts) -> apps/web"
      mkdir -p apps

      # 1) Create Vite skeleton FIRST (must be empty)
      create_vite_skeleton "apps/web" "react-ts"

      # 2) Template owns deps: replace package.json + install
      if [[ -f "$TEMPLATES_DIR/apps/$ui/package.json" ]]; then
        log "Replacing Vite package.json with template package.json (advanced deps)"
        cp "$TEMPLATES_DIR/apps/$ui/package.json" "apps/web/package.json"
      fi
      (cd "apps/web" && npm install)

      # 3) Overlay template src
      overlay_ui_src "$ui" "apps/web"

      # Fail loudly if overlay didn't create expected structure
      [[ -f "apps/web/src/App.tsx" ]] || die "Missing apps/web/src/App.tsx after overlay"
      [[ -d "apps/web/src/app" ]] || die "Overlay failed: apps/web/src/app not created"
      ;;
    web-vanilla)
      log "Scaffolding Vite app (vanilla-ts) -> apps/web"
      mkdir -p apps

      # 1) Create Vite skeleton FIRST
      create_vite_skeleton "apps/web" "vanilla-ts"

      # 2) Template owns deps (optional)
      if [[ -f "$TEMPLATES_DIR/apps/$ui/package.json" ]]; then
        log "Replacing Vite package.json with template package.json (vanilla deps)"
        cp "$TEMPLATES_DIR/apps/$ui/package.json" "apps/web/package.json"
      fi
      (cd "apps/web" && npm install)

      # 3) Overlay template src (if present)
      if [[ -d "$TEMPLATES_DIR/apps/$ui/src" ]]; then
        overlay_ui_src "$ui" "apps/web"
      fi
      ;;
    desktop-tauri)
      log "Scaffolding desktop placeholder -> apps/desktop"
      mkdir -p apps/desktop/src
      if [[ -d "$TEMPLATES_DIR/apps/$ui/src" ]]; then
        cp -R "$TEMPLATES_DIR/apps/$ui/src"/. "apps/desktop/src/"
      fi
      ;;
    *)
      die "Unknown UI: $ui"
      ;;
  esac
done

# ----------------------------
# Git / GitHub setup (after files exist)
# ----------------------------
git_init_if_needed
git_commit_scaffolded_changes
ensure_github_repo_and_push "$GITHUB_OWNER" "$PROJECT"

# ----------------------------
# Done
# ----------------------------
log "Scaffold complete: $PROJECT"
log "GitHub: https://github.com/$GITHUB_OWNER/$PROJECT"
log "Next:"
log "  cd $PROJECT"
log "  ./scripts/provision.sh"
if [[ "$EXAMPLE" == "advanced" ]]; then
  log "  (advanced) netlify dev"
  if [[ -x "scripts/test-api.sh" ]]; then
    log "  (advanced) ./scripts/test-api.sh  # after setting SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY"
  fi
fi
