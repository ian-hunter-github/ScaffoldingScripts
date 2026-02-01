# Provisioning: **PROJECT_NAME**

This project is scaffolded to use:

* **Deployment**: Netlify
* **Database**: Supabase (Postgres)

Provisioning is handled by:

```
./scripts/provision.sh
```

This script is **safe to re-run**.

---

## Prerequisites

Before provisioning, ensure you are logged in:

```
netlify login
supabase login
```

Check tool availability:

```
node scripts/check-tools.mjs
```

---

## Basic provisioning (recommended first run)

```
./scripts/provision.sh
```

This will:

1. Ensure Netlify authentication
2. Create or link a Netlify site for this project
3. Import `.env` into Netlify environment variables
4. Link an existing Supabase project
5. Prompt for Supabase runtime credentials
6. Re-import `.env` into Netlify

You will be asked for:

* `SUPABASE_PROJECT_REF`
* `SUPABASE_URL`
* `VITE_SUPABASE_URL`
* `VITE_SUPABASE_ANON_KEY`
* `SUPABASE_SERVICE_ROLE_KEY`

**Important:** The service role key must never be exposed to browser code. It is used only by Netlify Functions.

---

## Creating a Supabase project automatically (optional)

To attempt project creation via the Supabase CLI:

```
./scripts/provision.sh --sb-create
```

Project creation parameters are read from:

```
supabase.config.json
```

This file contains **non-secret intent only** (project name, org slug, region, provider).

If creation fails (permissions or CLI limitations), you will be prompted to provide an existing project ref.

---

## Applying the example database schema

The scaffold includes an example table and seed data:

* `sql/bootstrap.sql` — creates tables (idempotent)
* `sql/seed.sql` — inserts example rows

To apply them:

```
./scripts/provision.sh --apply-schema
```

The script will attempt to run the SQL using the Supabase CLI. If your CLI does not support direct execution, you will be instructed to run the SQL manually in the Supabase dashboard SQL editor.

---

## Re-provisioning into a different Supabase org or region

To re-provision later:

1. Edit `supabase.config.json`
2. Run:

   ```
   ./scripts/provision.sh --sb-create --apply-schema
   ```

This allows you to recreate the same example schema in a different Supabase workspace or region.

---

## Runtime configuration

Runtime access is provided via:

* `.env` (local development)
* Netlify environment variables (deployment)

The following variables must be present:

```
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
VITE_SUPABASE_URL
VITE_SUPABASE_ANON_KEY
```

---

## Summary

* `scaffold.sh` creates files only
* `provision.sh` wires cloud resources
* Schema creation is explicit and opt-in
* Provisioning is deterministic and repeatable
