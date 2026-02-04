#!/usr/bin/env bash
set -euo pipefail

T="$HOME/Projects/Scripts/Templates/apps/web-react/src"
mkdir -p "$T/app"

echo "[fix] Setting Templates/apps/web-react/src/App.tsx to re-export src/app/App.tsx"
cat > "$T/App.tsx" <<'TSX'
import App from "./app/App";
export default App;
TSX

echo "[fix] Ensuring Templates/apps/web-react/src/app/App.tsx contains Projects + Tasks UI"

cat > "$T/app/App.tsx" <<'TSX'
import { useEffect, useState } from "react";

type Project = { id: string; name: string };
type Task = { id: string; title: string; done: boolean };

export default function App() {
  const [projects, setProjects] = useState<Project[]>([]);
  const [projectId, setProjectId] = useState<string>("");
  const [tasks, setTasks] = useState<Task[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const res = await fetch("/.netlify/functions/projects");
        const json = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error((json as any)?.error || `HTTP ${res.status}`);
        const list = (json as any)?.projects ?? [];
        setProjects(list);
        if (list.length) setProjectId(list[0].id);
      } catch (e: any) {
        setError(String(e?.message || e));
      }
    })();
  }, []);

  useEffect(() => {
    if (!projectId) return;
    (async () => {
      try {
        const res = await fetch(`/.netlify/functions/tasks?projectId=${encodeURIComponent(projectId)}`);
        const json = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error((json as any)?.error || `HTTP ${res.status}`);
        setTasks((json as any)?.tasks ?? []);
      } catch (e: any) {
        setError(String(e?.message || e));
        setTasks([]);
      }
    })();
  }, [projectId]);

  return (
    <div style={{ padding: 16, display: "grid", gridTemplateColumns: "320px 1fr", gap: 16 }}>
      <div>
        <h1 style={{ marginTop: 0 }}>Projects</h1>
        {error && <p style={{ color: "crimson" }}>Error: {error}</p>}
        <ul style={{ listStyle: "none", padding: 0, margin: 0 }}>
          {projects.map((p) => (
            <li key={p.id} style={{ marginBottom: 8 }}>
              <button
                onClick={() => setProjectId(p.id)}
                style={{
                  width: "100%",
                  textAlign: "left",
                  padding: 10,
                  borderRadius: 8,
                  border: "1px solid #ddd",
                  background: p.id === projectId ? "#f3f3f3" : "white",
                  cursor: "pointer",
                }}
              >
                {p.name}
              </button>
            </li>
          ))}
        </ul>
      </div>

      <div>
        <h2 style={{ marginTop: 0 }}>Tasks</h2>
        {!projectId && <p>Select a project.</p>}
        {projectId && tasks.length === 0 && <p>No tasks for this project.</p>}
        <ul style={{ paddingLeft: 18 }}>
          {tasks.map((t) => (
            <li key={t.id}>
              {t.done ? "✅ " : ""}{t.title}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
TSX

echo "[fix] Done. Templates updated."
