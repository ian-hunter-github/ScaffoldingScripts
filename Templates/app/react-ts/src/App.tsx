import { useEffect, useState } from "react";
import "./App.css";

type HealthcheckResponse =
  | { ok: true; source: string; db: string; message?: string; row?: any }
  | { ok: false; error: string };

export default function App() {
  const [data, setData] = useState<HealthcheckResponse | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch("/.netlify/functions/healthcheck");
        const json = (await res.json()) as HealthcheckResponse;
        if (!cancelled) setData(json);
      } catch (e: any) {
        if (!cancelled)
          setData({ ok: false, error: e?.message || String(e) });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div
      style={{
        fontFamily: "system-ui, sans-serif",
        maxWidth: 720,
        margin: "2rem auto",
      }}
    >
      <h1>Netlify + (optional) Supabase starter</h1>
      <p>
        Calling <code>/.netlify/functions/healthcheck</code>
      </p>
      <pre
        style={{
          padding: "1rem",
          background: "#111",
          color: "#eee",
          borderRadius: 8,
          overflow: "auto",
        }}
      >
        {data ? JSON.stringify(data, null, 2) : "Loading…"}
      </pre>
    </div>
  );
}
