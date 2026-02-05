import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";

export function mkEvent({ method = "GET", bodyObj, query } = {}) {
  return {
    httpMethod: method,
    headers: { "content-type": "application/json" },
    queryStringParameters: query ?? {},     // <-- change this line
    body: bodyObj === undefined ? null : JSON.stringify(bodyObj),
  };
}

export function parseJsonBody(resp) {
  if (!resp || typeof resp.body !== "string") return null;
  try { return JSON.parse(resp.body); } catch { return null; }
}

export function uniqueName(prefix = "it") {
  return `${prefix}-${new Date().toISOString().replace(/[:.TZ-]/g, "")}-${randomUUID().slice(0, 8)}`;
}

export function assertEnv() {
  const url = process.env.SUPABASE_URL || "";
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
  if (!url || !key) {
    throw new Error(
      "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in environment.\n" +
      "Tip: export them from .env then run tests.\n" +
      "  export SUPABASE_URL=\"$(grep SUPABASE_URL .env | cut -d= -f2-)\"\n" +
      "  export SUPABASE_SERVICE_ROLE_KEY=\"$(grep SUPABASE_SERVICE_ROLE_KEY .env | cut -d= -f2-)\"\n"
    );
  }
}

export async function retry(fn, { tries = 5, delayMs = 250 } = {}) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try { return await fn(); }
    catch (e) { lastErr = e; if (i < tries - 1) await sleep(delayMs); }
  }
  throw lastErr;
}
