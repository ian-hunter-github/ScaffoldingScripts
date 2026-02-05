import {
  handleOptions,
  ok,
  created,
  badRequest,
  serverError,
  methodNotAllowed,
  getQuery,
} from "./_lib/http.mjs";
import { readJsonBody, requireString, optionalString, optionalBoolean } from "./_lib/validate.mjs";
import { ensureSupabaseClient, mapDbError } from "./_lib/supabase.mjs";

export async function handler(event) {
  const opt = handleOptions(event);
  if (opt) return opt;

  const method = (event.httpMethod || "GET").toUpperCase();

  const supa = ensureSupabaseClient();
  if (!supa.ok) return serverError(supa.error, supa.hint);
  const supabase = supa.client;

  if (method === "GET") {
    const q = getQuery(event);
    const projectId = q.project_id || "";

    if (!projectId) {
      return badRequest("project_id query param is required", "Call /tasks?project_id=<uuid>");
    }

    const { data, error } = await supabase
      .from("tasks")
      .select("id,project_id,title,done,created_at")
      .eq("project_id", projectId)
      .order("created_at", { ascending: false });

    if (error) return serverError(mapDbError(error));
    return ok(data || []);
  }

  if (method === "POST") {
    const body = readJsonBody(event);
    if (!body.ok) return badRequest(body.error);

    const projectId = requireString(body.value, "project_id", { min: 1, max: 80 });
    if (!projectId.ok) return badRequest(projectId.error);

    const title = requireString(body.value, "title", { min: 1, max: 200 });
    if (!title.ok) return badRequest(title.error);

    const { data, error } = await supabase
      .from("tasks")
      .insert({ project_id: projectId.value, title: title.value, done: false })
      .select("id,project_id,title,done,created_at")
      .single();

    if (error) return serverError(mapDbError(error));
    return created(data);
  }

  if (method === "PATCH") {
    const body = readJsonBody(event);
    if (!body.ok) return badRequest(body.error);

    const id = requireString(body.value, "id", { min: 1, max: 80 });
    if (!id.ok) return badRequest(id.error);

    const title = optionalString(body.value, "title", { min: 1, max: 200 });
    if (!title.ok) return badRequest(title.error);

    const isDone = optionalBoolean(body.value, "done");
    if (!isDone.ok) return badRequest(isDone.error);

    const patch = {};
    if (title.value !== undefined) patch.title = title.value;
    if (isDone.value !== undefined) patch.done = isDone.value;

    if (Object.keys(patch).length === 0) {
      return badRequest("No fields to update", "Provide at least one of: title, done");
    }

    const { data, error } = await supabase
      .from("tasks")
      .update(patch)
      .eq("id", id.value)
      .select("id,project_id,title,done,created_at")
      .single();

    if (error) return serverError(mapDbError(error));
    return ok(data);
  }

  if (method === "DELETE") {
    const q = getQuery(event);
    const id = q.id || "";
    if (!id) return badRequest("id query param is required", "Call /tasks?id=<uuid>");

    const { error } = await supabase.from("tasks").delete().eq("id", id);
    if (error) return serverError(mapDbError(error));

    return ok({ id });
  }

  return methodNotAllowed(method);
}
