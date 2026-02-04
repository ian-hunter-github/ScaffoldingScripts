export default async (req) => {
  return new Response(
    JSON.stringify({
      ok: true,
      source: "netlify-function",
      db: "none",
      message: "Hello from Netlify Functions (no DB)",
    }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
};
