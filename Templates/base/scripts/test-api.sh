#!/usr/bin/env bash
set -euo pipefail

# Load .env for Node tests (Netlify Dev loads it automatically; plain Node does not)
if [[ -f .env ]]; then
  export SUPABASE_URL="$(grep '^SUPABASE_URL=' .env | cut -d= -f2- | tr -d '\r')"
  export SUPABASE_SERVICE_ROLE_KEY="$(grep '^SUPABASE_SERVICE_ROLE_KEY=' .env | cut -d= -f2- | tr -d '\r')"
fi

node --test tests/api