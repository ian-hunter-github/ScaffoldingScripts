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
  return json.data;
}

test("tasks: GET requires project_id", async () => {
  assertEnv();

  const resp = await tasks(mkEvent({ method: "GET" }));
  assert.equal(resp.statusCode, 400);

  const json = parseJsonBody(resp);
  assert.ok(json?.error);
});

test("tasks: lifecycle (create/list/patch/delete)", async () => {
  assertEnv();

  const projectId = await createProject();
  const t1 = await createTask(projectId);

  const listResp = await tasks(mkEvent({ method: "GET", query: { project_id: projectId } }));
  if (listResp.statusCode !== 200) {
    console.error("LIST FAIL:", listResp.statusCode, listResp.body);
  }

  assert.equal(listResp.statusCode, 200);
  const listJson = parseJsonBody(listResp);
  assert.ok(Array.isArray(listJson?.data));
  assert.ok(listJson.data.some((t) => t.id === t1.id));

  const patchResp = await tasks(mkEvent({ method: "PATCH", bodyObj: { id: t1.id, done: true } }));
  assert.equal(patchResp.statusCode, 200);
  const patchJson = parseJsonBody(patchResp);
  assert.equal(patchJson?.data?.id, t1.id);
  assert.equal(patchJson?.data?.done, true);

  const delResp = await tasks(mkEvent({ method: "DELETE", query: { id: t1.id } }));
  assert.equal(delResp.statusCode, 200);
  const delJson = parseJsonBody(delResp);
  assert.equal(delJson?.data?.id, t1.id);
});
