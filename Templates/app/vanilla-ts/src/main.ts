import "./style.css";

type HealthcheckResponse =
  | { ok: true; source: string; db: string; message?: string; row?: any }
  | { ok: false; error: string };

const el = document.querySelector<HTMLDivElement>("#app");
if (!el) throw new Error("#app not found");

el.innerHTML = `
  <div style="font-family: system-ui, sans-serif; max-width: 720px; margin: 2rem auto;">
    <h1>Netlify + (optional) Supabase starter</h1>
    <p>Calling <code>/.netlify/functions/healthcheck</code>…</p>
    <pre id="out" style="padding: 1rem; background: #111; color: #eee; border-radius: 8px; overflow:auto;"></pre>
  </div>
`;

const out = document.querySelector<HTMLPreElement>("#out")!;

async function run() {
  try {
    const res = await fetch("/.netlify/functions/healthcheck");
    const json = (await res.json()) as HealthcheckResponse;
    out.textContent = JSON.stringify(json, null, 2);
  } catch (e: any) {
    out.textContent = JSON.stringify(
      { ok: false, error: e?.message || String(e) },
      null,
      2
    );
  }
}

run();
