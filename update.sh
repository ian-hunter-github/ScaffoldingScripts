#!/usr/bin/env bash
set -euo pipefail

# write-api-functions.sh
# Writes ESM Netlify Functions templates under:
#   Scripts/Templates/base/services/api/netlify/functions/

ROOT_DIR="$(pwd)"
TEMPL_DIR="$ROOT_DIR/Scripts/Templates/base/services/api/netlify/functions"
LIB_DIR="$TEMPL_DIR/_lib"

mkdir -p "$LIB_DIR"

# -------------------------
# _lib/http.mjs
# -------------------------
cat > "$LIB_DIR/http.mjs" <<'EOF'
export const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,PATCH,DELETE,OPTIONS",
  "access-control-allow-headers": "content-type",
  "access-control-max-age": "86400",
};

export function json(statusCode, body, extraHeaders = {}) {
  return {
    statusCode,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...CORS_HEADERS,
      ...extraHeaders,
    },
    body: JSON.stringify(body ?? null),
  };
}

export function ok(data) {
  return json(200, { data });
}

export function created(data) {
  return json(201, { data });
}

export function badRequest(message, hint) {
  return json(400, { error: message, ...(hint ? { hint } : {}) });
}

export function notFound(message = "Not found") {
  return json(404, { error: message });
}

export function methodNotAllowed(method) {
  return json(405, { error: `Method not allowed: ${method}` });
}

export function serverError(message, hint) {
  return json(500, { error: message, ...(hint ? { hint } : {}) });
}

export function handleOptions(event) {
  if ((event.httpMethod || "").toUpperCase() === "OPTIONS") {
    return json(204, null);
  }
  return null;
}

export function getQuery(event) {
  return event.queryStringParameters || {};
}
EOF

# -------------------------
# _lib/validate.mjs
# -------------------------
cat > "$LIB_DIR/validate.mjs" <<'EOF'
export function safeJsonParse(text) {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch (e) {
    return { ok: false, error: e };
  }
}

export function readJsonBody(event) {
  const raw = event.body ?? "";
  if (!raw) return { ok: true, value: {} };

  const parsed = safeJsonParse(raw);
  if (!parsed.ok) return { ok: false, error: "Invalid JSON body" };
  if (parsed.value === null || typeof parsed.value !== "object" || Array.isArray(parsed.value)) {
    return { ok: false, error: "JSON body must be an object" };
  }
  return { ok: true, value: parsed.value };
}

export function requireString(obj, key, { min = 1, max = 200 } = {}) {
  const v = obj?.[key];
  if (typeof v !== "string") return { ok: false, error: `${key} must be a string` };
  const s = v.trim();
  if (s.length < min) return { ok: false, error: `${key} must be at least ${min} characters` };
  if (s.length > max) return { ok: false, error: `${key} must be at most ${max} characters` };
  return { ok: true, value: s };
}

export function optionalString(obj, key, { min = 0, max = 200 } = {}) {
  const v = obj?.[key];
  if (v === undefined) return { ok: true, value: undefined };
  if (typeof v !== "string") return { ok: false, error: `${key} must be a string` };
  const s = v.trim();
  if (s.length < min) return { ok: false, error: `${key} must be at least ${min} characters` };
  if (s.length > max) return { ok: false, error: `${key} must be at most ${max} characters` };
  return { ok: true, value: s };
}

export function optionalBoolean(obj, key) {
  const v = obj?.[key];
  if (v === undefined) return { ok: true, value: undefined };
  if (typeof v !== "boolean") return { ok: false, error: `${key} must be a boolean` };
  return { ok: true, value: v };
}
EOF

# -------------------------
# _lib/supabase.mjs
# -------------------------
cat > "$LIB_DIR/supabase.mjs" <<'EOF'
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
EOF

# -------------------------
# projects.mjs
# -------------------------
cat > "$TEMPL_DIR/projects.mjs" <<'EOF'
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
EOF

# -------------------------
# tasks.mjs
# -------------------------
cat > "$TEMPL_DIR/tasks.mjs" <<'EOF'
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
EOF

echo "✅ Wrote API function templates to:"
echo "   $TEMPL_DIR"
echo
echo "Next requirements (make sure these are true in Templates/base/package.json):"
echo "  - \"type\": \"module\""
echo "  - dependency: @supabase/supabase-js"
echo
echo "Done."
