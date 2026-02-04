#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# defaults
# ------------------------------------------------------------
UIS=()
EXAMPLE="minimal"
DB="none"

usage() {
  cat <<'TXT'
Usage:
  scaffold.sh <project-name> [options]

Options:
  --ui web-react|mobile-react-native|desktop-tauri   (repeatable)
  --example minimal|advanced
  --db none|supabase
  -h, --help

Examples:
  scaffold.sh myapp --ui web-react
  scaffold.sh myapp --ui web-react --ui mobile-react-native --example advanced --db supabase
TXT
}

log() { printf '[scaffold] %s\n' "$*"; }
die() { printf '[scaffold] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

copy_dir() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || die "Missing template dir: $src"
  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/
}

create_vite_app() {
  local dst="$1" template="$2"
  [[ -n "$dst" ]] || die "create_vite_app: missing dst"
  [[ -n "$template" ]] || die "create_vite_app: missing template"
  [[ ! -e "$dst" ]] || die "Vite destination already exists (refusing to overwrite): $dst"

  log "Creating Vite app: $dst (template=$template)"
  mkdir -p "$(dirname "$dst")"

  # Force non-interactive behaviour.
  # - CI=1 suppresses prompts in many CLIs
  # - printf 'n\n' answers the rolldown question “No” if it still appears
  CI=1 printf 'n\n' | npm create vite@latest "$dst" -- --template "$template" --no-install

  (cd "$dst" && npm install)
}

write_meta_json() {
  local mode="$1" example="$2" db="$3"
  node - "$mode" "$example" "$db" "${UIS[@]}" <<'NODE'
const fs = require('fs');

const mode = process.argv[2];
const example = process.argv[3];
const db = process.argv[4];
const uis = process.argv.slice(5);

const meta = { mode, ui: uis, example, db };
fs.writeFileSync('.scaffold/meta.json', JSON.stringify(meta, null, 2));
NODE
}

overlay_ui_src() {
  local ui="$1" appdir="$2"
  local srcdir="$TEMPLATES_DIR/apps/$ui/src"
  local dstdir="$appdir/src"

  log "Looking for UI template src dir: $srcdir"
  [[ -d "$srcdir" ]] || die "UI template src dir missing: $srcdir"

  log "Overlaying UI src: $ui -> $dstdir"
  copy_dir "$srcdir" "$dstdir"
}

# ------------------------------------------------------------
# args
# ------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }
PROJECT="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui) UIS+=("$2"); shift 2 ;;
    --example) EXAMPLE="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "${#UIS[@]}" -gt 0 ]] || die "At least one --ui is required"
case "$EXAMPLE" in minimal|advanced) ;; *) die "Invalid --example: $EXAMPLE" ;; esac
case "$DB" in none|supabase) ;; *) die "Invalid --db: $DB" ;; esac
[[ ! -e "$PROJECT" ]] || die "Path already exists: $PROJECT"

MODE="single"
[[ "${#UIS[@]}" -gt 1 ]] && MODE="monorepo"

# ------------------------------------------------------------
# locate Templates
# ------------------------------------------------------------
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPTS_DIR/Templates"

[[ -d "$TEMPLATES_DIR" ]] || die "Templates directory missing: $TEMPLATES_DIR"
[[ -f "$TEMPLATES_DIR/provision.sh" ]] || die "Missing template: $TEMPLATES_DIR/provision.sh"
[[ -f "$TEMPLATES_DIR/check-tools.mjs" ]] || die "Missing template: $TEMPLATES_DIR/check-tools.mjs"
[[ -f "$TEMPLATES_DIR/base/netlify.toml" ]] || die "Missing template: $TEMPLATES_DIR/base/netlify.toml"

need_cmd node
need_cmd npm

# ------------------------------------------------------------
# create project
# ------------------------------------------------------------
mkdir "$PROJECT"
cd "$PROJECT"

mkdir -p .scaffold
write_meta_json "$MODE" "$EXAMPLE" "$DB"

mkdir -p scripts
cp "$TEMPLATES_DIR/provision.sh" scripts/provision.sh
cp "$TEMPLATES_DIR/check-tools.mjs" scripts/check-tools.mjs
chmod +x scripts/provision.sh

# Always create a netlify.toml at repo root
cp "$TEMPLATES_DIR/base/netlify.toml" netlify.toml

# ------------------------------------------------------------
# base templates (advanced example only)
# ------------------------------------------------------------
if [[ "$EXAMPLE" == "advanced" ]]; then
  log "Applying base templates (advanced)"
  copy_dir "$TEMPLATES_DIR/base/sql" sql
  copy_dir "$TEMPLATES_DIR/base/services" services
  copy_dir "$TEMPLATES_DIR/base/packages" packages

  # Support either name, but write as package.json in project root
  if [[ -f "$TEMPLATES_DIR/base/package.json" ]]; then
    cp "$TEMPLATES_DIR/base/package.json" package.json
  elif [[ -f "$TEMPLATES_DIR/base/packages.json" ]]; then
    cp "$TEMPLATES_DIR/base/packages.json" package.json
  fi

  if [[ -f "package.json" ]]; then
    npm install
  fi
fi

# DB config template
if [[ "$DB" == "supabase" ]]; then
  [[ -f "$TEMPLATES_DIR/base/supabase.config.json" ]] || die "Missing template: $TEMPLATES_DIR/base/supabase.config.json"
  sed "s/__PROJECT_NAME__/${PROJECT}/g" \
    "$TEMPLATES_DIR/base/supabase.config.json" > supabase.config.json
fi

# ------------------------------------------------------------
# apps
# ------------------------------------------------------------
mkdir -p apps

for ui in "${UIS[@]}"; do
  case "$ui" in
    web-react)
      # 1) Create the Vite app FIRST
      create_vite_app "apps/web" "react-ts"

      # 2) Option A: template owns package.json for the app
      if [[ -f "$TEMPLATES_DIR/apps/$ui/package.json" ]]; then
        log "Copying template package.json for $ui -> apps/web/package.json"
        cp "$TEMPLATES_DIR/apps/$ui/package.json" "apps/web/package.json"
        (cd "apps/web" && npm install)
      else
        die "Missing template package.json for $ui: $TEMPLATES_DIR/apps/$ui/package.json"
      fi

      # 3) Overlay template src/ into the created app
      overlay_ui_src "$ui" "apps/web"

      # Fail loudly if overlay didn't create expected structure
      [[ -f "apps/web/src/App.tsx" ]] || die "Missing apps/web/src/App.tsx after overlay"
      [[ -d "apps/web/src/app" ]] || die "Overlay failed: apps/web/src/app not created"
      ;;

    mobile-react-native)
      mkdir -p apps/mobile/src
      overlay_ui_src "$ui" "apps/mobile"
      ;;
    desktop-tauri)
      mkdir -p apps/desktop/src
      overlay_ui_src "$ui" "apps/desktop"
      ;;
    *)
      die "Unknown UI: $ui"
      ;;
  esac
done

# ------------------------------------------------------------
# git init (optional, safe)
# ------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  if [[ ! -d .git ]]; then
    git init >/dev/null 2>&1 || true
    git add -A >/dev/null 2>&1 || true
    git commit -m "Scaffold project" >/dev/null 2>&1 || true
  fi
fi

log "Scaffold complete:"
log "  project: $PROJECT"
log "  mode:    $MODE"
log "  ui:      ${UIS[*]}"
log "  example: $EXAMPLE"
log "  db:      $DB"
log ""
log "Next:"
log "  cd $PROJECT"
log "  ./scripts/provision.sh --create-db --apply-schema"
log "  netlify dev"
