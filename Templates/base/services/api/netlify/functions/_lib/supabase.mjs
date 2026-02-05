import { createClient } from "@supabase/supabase-js";

let _client = null;

export function getSupabaseEnv() {
  const url = process.env.SUPABASE_URL || "";
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
  return { url, key };
}

export function ensureSupabaseClient() {
  const { url, key } = getSupabaseEnv();

  if (!url || !key) {
    return {
      ok: false,
      error: "Supabase env not configured",
      hint: "Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in .env (manual paste), then restart netlify dev.",
    };
  }

  if (!_client) {
    _client = createClient(url, key, {
      auth: { persistSession: false },
    });
  }

  return { ok: true, client: _client };
}

export function mapDbError(err) {
  // Low-leak error: preserve message but avoid dumping internal objects.
  return err?.message || "Database error";
}
