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
