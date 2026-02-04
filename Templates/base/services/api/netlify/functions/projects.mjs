import { createClient } from "@supabase/supabase-js";

export async function handler() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    return { statusCode: 500, body: JSON.stringify({ error: "Missing Supabase env" }) };
  }

  const sb = createClient(url, key);
  const { data, error } = await sb
    .from("projects")
    .select("id,name,created_at")
    .order("created_at", { ascending: true });

  if (error) {
    return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
  }

  return {
    statusCode: 200,
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projects: data ?? [] }),
  };
}
