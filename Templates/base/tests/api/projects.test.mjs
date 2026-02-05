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
