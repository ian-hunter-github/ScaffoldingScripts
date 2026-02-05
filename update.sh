#!/usr/bin/env bash
set -euo pipefail

# write-api-integration-tests.sh
# Writes API integration tests (Node built-in test runner) into:
#   Scripts/Templates/base/tests/api/
#
# These tests call Netlify Function handlers directly (no netlify dev required).
# They require real Supabase env vars at test time:
#   SUPABASE_URL
#   SUPABASE_SERVICE_ROLE_KEY
#
# NOTE: Your scaffold.sh must copy Templates/base/tests into new projects for these
# to appear in scaffolded output (if it doesn’t already).

ROOT_DIR="${HOME}"
OUT_DIR="$ROOT_DIR/Scripts/Templates/base/tests/api"

mkdir -p "$OUT_DIR"

# -------------------------
# helpers.mjs
# -------------------------
cat > "$OUT_DIR/helpers.mjs" <<'EOF'
import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";

/**
 * Minimal Netlify event builder for handler(event).
 */
export function mkEvent({ method = "GET", bodyObj, query } = {}) {
  const ev = {
    httpMethod: method,
    headers: {
      "content-type": "application/json",
    },
    queryStringParameters: query || undefined,
    body: bodyObj === undefined ? null : JSON.stringify(bodyObj),
  };
  return ev;
}

export function parseJsonBody(resp) {
  if (!resp || typeof resp.body !== "string") return null;
  try {
    return JSON.parse(resp.body);
  } catch {
    return null;
  }
}

export function uniqueName(prefix = "it") {
  return `${prefix}-${new Date().toISOString().replace(/[:.TZ-]/g, "")}-${randomUUID().slice(0, 8)}`;
}

export function assertEnv() {
  const url = process.env.SUPABASE_URL || "";
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
  if (!url || !key) {
    const msg =
      "Missing required env vars for integration tests.\n" +
      "Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY, then re-run.\n\n" +
      "Example:\n" +
      "  export SUPABASE_URL='https://xxxxx.supabase.co'\n" +
      "  export SUPABASE_SERVICE_ROLE_KEY='...'\n" +
      "  node --test tests/api/*.test.mjs\n";
    throw new Error(msg);
  }
}

export async function retry(fn, { tries = 5, delayMs = 250 } = {}) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      if (i < tries - 1) await sleep(delayMs);
    }
  }
  throw lastErr;
}
EOF

# -------------------------
# projects.test.mjs
# -------------------------
cat > "$OUT_DIR/projects.test.mjs" <<'EOF'
import test from "node:test";
import assert from "node:assert/strict";

import { handler as projects } from "../../services/api/netlify/functions/projects.mjs";
import { assertEnv, mkEvent, parseJsonBody, uniqueName } from "./helpers.mjs";

test("projects: GET returns {data: array}", async () => {
  assertEnv();

  const resp = await projects(mkEvent({ method: "GET" }));
  assert.equal(resp.statusCode, 200);

  const json = parseJsonBody(resp);
  assert.ok(json);
  assert.ok(Array.isArray(json.data));
});

test("projects: POST creates a project", async () => {
  assertEnv();

  const name = uniqueName("proj");
  const resp = await projects(mkEvent({ method: "POST", bodyObj: { name } }));
  assert.equal(resp.statusCode, 201);

  const json = parseJsonBody(resp);
  assert.ok(json?.data?.id);
  assert.equal(json.data.name, name);
});

test("projects: POST validates body", async () => {
  assertEnv();

  const resp = await projects(mkEvent({ method: "POST", bodyObj: { name: "" } }));
  assert.equal(resp.statusCode, 400);

  const json = parseJsonBody(resp);
  assert.ok(json?.error);
});
EOF

# -------------------------
# tasks.test.mjs
# -------------------------
cat > "$OUT_DIR/tasks.test.mjs" <<'EOF'
import test from "node:test";
import assert from "node:assert/strict";

import { handler as projects } from "../../services/api/netlify/functions/projects.mjs";
import { handler as tasks } from "../../services/api/netlify/functions/tasks.mjs";
import { assertEnv, mkEvent, parseJsonBody, uniqueName } from "./helpers.mjs";

async function createProject() {
  const name = uniqueName("proj");
  const resp = await projects(mkEvent({ method: "POST", bodyObj: { name } }));
  assert.equal(resp.statusCode, 201);
  const json = parseJsonBody(resp);
  assert.ok(json?.data?.id);
  return json.data.id;
}

async function createTask(project_id) {
  const title = uniqueName("task");
  const resp = await tasks(mkEvent({ method: "POST", bodyObj: { project_id, title } }));
  assert.equal(resp.statusCode, 201);
  const json = parseJsonBody(resp);
  assert.ok(json?.data?.id);
  assert.equal(json.data.project_id, project_id);
  return json.data;
}

test("tasks: GET requires project_id", async () => {
  assertEnv();

  const resp = await tasks(mkEvent({ method: "GET" }));
  assert.equal(resp.statusCode, 400);

  const json = parseJsonBody(resp);
  assert.ok(json?.error);
});

test("tasks: full lifecycle (create/list/patch/delete)", async () => {
  assertEnv();

  const projectId = await createProject();

  // create
  const t1 = await createTask(projectId);

  // list
  const listResp = await tasks(mkEvent({ method: "GET", query: { project_id: projectId } }));
  assert.equal(listResp.statusCode, 200);
  const listJson = parseJsonBody(listResp);
  assert.ok(Array.isArray(listJson?.data));
  assert.ok(listJson.data.some((t) => t.id === t1.id));

  // patch
  const patchResp = await tasks(
    mkEvent({
      method: "PATCH",
      bodyObj: { id: t1.id, done: true },
    })
  );
  assert.equal(patchResp.statusCode, 200);
  const patchJson = parseJsonBody(patchResp);
  assert.equal(patchJson?.data?.id, t1.id);
  assert.equal(patchJson?.data?.done, true);

  // delete
  const delResp = await tasks(mkEvent({ method: "DELETE", query: { id: t1.id } }));
  assert.equal(delResp.statusCode, 200);
  const delJson = parseJsonBody(delResp);
  assert.equal(delJson?.data?.id, t1.id);
});
EOF

# -------------------------
# Optional runner script template
# -------------------------
RUNNER_DIR="$ROOT_DIR/Scripts/Templates/base/scripts"
mkdir -p "$RUNNER_DIR"

cat > "$RUNNER_DIR/test-api.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Runs API integration tests (Node built-in test runner).
# Requires:
#   SUPABASE_URL
#   SUPABASE_SERVICE_ROLE_KEY
#
# Example:
#   export SUPABASE_URL="https://xxxxx.supabase.co"
#   export SUPABASE_SERVICE_ROLE_KEY="..."
#   ./scripts/test-api.sh

node --test tests/api/*.test.mjs
EOF
chmod +x "$RUNNER_DIR/test-api.sh"

echo "✅ Wrote API integration tests to:"
echo "   $OUT_DIR"
echo
echo "✅ Wrote optional runner script template to:"
echo "   $RUNNER_DIR/test-api.sh"
echo
echo "Next step (if needed): ensure scaffold.sh copies these into new projects:"
echo "  - Templates/base/tests  -> project/tests"
echo "  - Templates/base/scripts/test-api.sh -> project/scripts/test-api.sh"
echo
echo "Run in a scaffolded project:"
echo "  export SUPABASE_URL='https://xxxxx.supabase.co'"
echo "  export SUPABASE_SERVICE_ROLE_KEY='...'"
echo "  ./scripts/test-api.sh"
