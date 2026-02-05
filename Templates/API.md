# REST API (Netlify Functions) — Projects + Tasks

This project exposes a small REST-ish API via Netlify Functions.

Base URL (local + deployed):

* `/.netlify/functions/projects`
* `/.netlify/functions/tasks`

These functions are designed to be:

* **Low-magic**: explicit inputs/outputs, no hidden background work
* **Deterministic**: same inputs → same results (given DB state)
* **Netlify-friendly**: works with Netlify Functions routing and HTTP methods
* **ESM**: uses `import` / `export` (no CommonJS `require`)

---

## Environment variables (required for Advanced example)

These functions require server-side Supabase access:

* `SUPABASE_URL`
* `SUPABASE_SERVICE_ROLE_KEY`

If either is missing, functions return HTTP **500** with a helpful hint.

> `SUPABASE_SERVICE_ROLE_KEY` is intentionally **manual** (paste into `.env`) to avoid hidden credential-fetching.

---

## Response shapes

### Success (2xx)

All success responses are wrapped:

```json
{ "data": ... }
```

### Error (non-2xx)

All errors are shaped as:

```json
{
  "error": "Short message",
  "hint": "Actionable hint (optional)"
}
```

---

## CORS

Functions return permissive CORS headers for development:

* `Access-Control-Allow-Origin: *`
* `Access-Control-Allow-Methods: GET,POST,PATCH,DELETE,OPTIONS`
* `Access-Control-Allow-Headers: content-type`

---

## Projects API

### GET `/projects`

List projects (most recent first).

**Request**

* Method: `GET`
* Body: none

**Response**

* `200 OK`

```json
{
  "data": [
    { "id": "uuid", "name": "My Project", "created_at": "2026-02-05T10:00:00Z" }
  ]
}
```

---

### POST `/projects`

Create a new project.

**Request**

* Method: `POST`
* Body:

```json
{ "name": "My Project" }
```

**Responses**

* `201 Created`

```json
{
  "data": { "id": "uuid", "name": "My Project", "created_at": "2026-02-05T10:00:00Z" }
}
```

* `400 Bad Request` (missing/invalid fields)

```json
{ "error": "name must be a string" }
```

---

## Tasks API

### GET `/tasks?project_id=<uuid>`

List tasks for a project (most recent first).

**Request**

* Method: `GET`
* Query:

  * `project_id` (required)

**Responses**

* `200 OK`

```json
{
  "data": [
    {
      "id": "uuid",
      "project_id": "uuid",
      "title": "First task",
      "done": false,
      "created_at": "2026-02-05T10:00:00Z"
    }
  ]
}
```

* `400 Bad Request` (missing `project_id`)

```json
{
  "error": "project_id query param is required",
  "hint": "Call /tasks?project_id=<uuid>"
}
```

---

### POST `/tasks`

Create a new task.

**Request**

* Method: `POST`
* Body:

```json
{
  "project_id": "uuid",
  "title": "Do the thing"
}
```

**Responses**

* `201 Created`

```json
{
  "data": {
    "id": "uuid",
    "project_id": "uuid",
    "title": "Do the thing",
    "done": false,
    "created_at": "2026-02-05T10:00:00Z"
  }
}
```

* `400 Bad Request` (missing/invalid fields)

```json
{ "error": "title must be at least 1 characters" }
```

---

### PATCH `/tasks`

Update a task. Only the provided fields are updated.

**Request**

* Method: `PATCH`
* Body:

```json
{
  "id": "uuid",
  "title": "New title",
  "done": true
}
```

**Rules**

* `id` is required.
* At least one of `title` or `done` must be provided.

**Responses**

* `200 OK`

```json
{
  "data": {
    "id": "uuid",
    "project_id": "uuid",
    "title": "New title",
    "done": true,
    "created_at": "2026-02-05T10:00:00Z"
  }
}
```

* `400 Bad Request` (no updatable fields)

```json
{
  "error": "No fields to update",
  "hint": "Provide at least one of: title, done"
}
```

---

### DELETE `/tasks?id=<uuid>`

Delete a task.

**Request**

* Method: `DELETE`
* Query:

  * `id` (required)

**Responses**

* `200 OK`

```json
{
  "data": { "id": "uuid" }
}
```

* `400 Bad Request` (missing `id`)

```json
{
  "error": "id query param is required",
  "hint": "Call /tasks?id=<uuid>"
}
```

---

## Local testing

Once provisioned and after pasting `SUPABASE_SERVICE_ROLE_KEY` into `.env`:

* Run: `netlify dev`
* Test endpoints:

```bash
curl -s http://localhost:8888/.netlify/functions/projects | jq
```

Create project:

```bash
curl -s -X POST http://localhost:8888/.netlify/functions/projects \
  -H "content-type: application/json" \
  -d '{"name":"Demo Project"}' | jq
```

List tasks:

```bash
curl -s "http://localhost:8888/.netlify/functions/tasks?project_id=<uuid>" | jq
```

---

## Notes / deliberate non-features

* No authentication in the demo API.
* Service role key is server-only and must never be exposed to the client.
* This API is intentionally small and stable to enable:

  * React implementation
  * vanilla-ts implementation
  * future desktop client (Tauri)
  * local AI model codegen against a fixed contract
