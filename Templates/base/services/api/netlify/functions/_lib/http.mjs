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
