import { createClient } from "@supabase/supabase-js";

export async function handler(event) {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    return { statusCode: 500, body: JSON.stringify({ error: "Missing Supabase env" }) };
  }

  const projectId = event.queryStringParameters?.projectId;
  if (!projectId) {
    return { statusCode: 400, body: JSON.stringify({ error: "projectId required" }) };
  }

  const sb = createClient(url, key);
  const { data, error } = await sb
    .from("tasks")
    .select("id,project_id,title,done,created_at")
    .eq("project_id", projectId)
    .order("created_at", { ascending: true });

  if (error) {
    return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
  }

  return {
    statusCode: 200,
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ tasks: data ?? [] }),
  };
}
