import { createClient } from "@supabase/supabase-js";

export default async (req) => {
  const url = process.env.SUPABASE_URL || "";
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || "";

  if (!url || !serviceKey) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in server env",
      }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const supabase = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });

  const { data, error } = await supabase
    .from("healthcheck")
    .select("name, created_at")
    .order("created_at", { ascending: false })
    .limit(1);

  if (error) {
    return new Response(
      JSON.stringify({ ok: false, error: error.message }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const row = (data && data[0]) || null;

  return new Response(
    JSON.stringify({
      ok: true,
      source: "netlify-function",
      db: "supabase",
      row,
    }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
};
