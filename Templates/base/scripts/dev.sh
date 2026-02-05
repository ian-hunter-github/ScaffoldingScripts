#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  echo "Missing .env in project root. Run ./scripts/provision.sh first." >&2
  exit 1
fi

# Export required env vars for Netlify functions AND Vite
for k in SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY VITE_SUPABASE_URL VITE_SUPABASE_ANON_KEY; do
  v="$(grep -E "^${k}=" .env | head -n1 | cut -d= -f2- | tr -d '\r' || true)"
  if [[ -z "$v" ]]; then
    echo "Missing $k in .env" >&2
    exit 1
  fi
  export "$k=$v"
done

exec netlify dev
