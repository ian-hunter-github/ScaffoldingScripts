import { handleOptions, ok, created, badRequest, serverError, methodNotAllowed } from "./_lib/http.mjs";
import { readJsonBody, requireString } from "./_lib/validate.mjs";
import { ensureSupabaseClient, mapDbError } from "./_lib/supabase.mjs";

export async function handler(event) {
  const opt = handleOptions(event);
  if (opt) return opt;

  const method = (event.httpMethod || "GET").toUpperCase();

  const supa = ensureSupabaseClient();
  if (!supa.ok) return serverError(supa.error, supa.hint);
  const supabase = supa.client;

  if (method === "GET") {
    const { data, error } = await supabase
      .from("projects")
      .select("id,name,created_at")
      .order("created_at", { ascending: false });

    if (error) return serverError(mapDbError(error));
    return ok(data || []);
  }

  if (method === "POST") {
    const body = readJsonBody(event);
    if (!body.ok) return badRequest(body.error);

    const name = requireString(body.value, "name", { min: 1, max: 120 });
    if (!name.ok) return badRequest(name.error);

    const { data, error } = await supabase
      .from("projects")
      .insert({ name: name.value })
      .select("id,name,created_at")
      .single();

    if (error) return serverError(mapDbError(error));
    return created(data);
  }

  return methodNotAllowed(method);
}
