#!/usr/bin/env bash
set -euo pipefail

BASE="$(pwd)/Templates"

echo "[templates] Writing Templates/ tree to:"
echo "  $BASE"
echo

mkdir -p \
  "$BASE/base/sql" \
  "$BASE/base/services/api/netlify/functions" \
  "$BASE/base/packages/shared/types" \
  "$BASE/apps/web-react/src/app" \
  "$BASE/apps/web-react/src/features/projects" \
  "$BASE/apps/web-react/src/store" \
  "$BASE/apps/mobile-react-native/src/features/projects" \
  "$BASE/apps/mobile-react-native/src/store" \
  "$BASE/apps/desktop-tauri/src"

# ------------------------------------------------------------
# Base SQL (advanced example)
# ------------------------------------------------------------
cat > "$BASE/base/sql/001_projects.sql" <<'SQL'
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  created_at timestamptz not null default now()
);
SQL

cat > "$BASE/base/sql/002_tasks.sql" <<'SQL'
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null,
  done boolean not null default false,
  created_at timestamptz not null default now()
);
SQL

# ------------------------------------------------------------
# Shared domain types
# ------------------------------------------------------------
cat > "$BASE/base/packages/shared/types/domain.ts" <<'TS'
export type Project = {
  id: string;
  name: string;
  description?: string;
  created_at: string;
};

export type Task = {
  id: string;
  project_id: string;
  title: string;
  done: boolean;
  created_at: string;
};
TS

# ------------------------------------------------------------
# Netlify REST API (projects)
# ------------------------------------------------------------
cat > "$BASE/base/services/api/netlify/functions/projects.mjs" <<'JS'
import { createClient } from "@supabase/supabase-js";

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

export default async (req) => {
  const url = new URL(req.url);
  const id = url.searchParams.get("id");

  if (req.method === "GET") {
    if (id) {
      const { data, error } = await supabase
        .from("projects")
        .select("*, tasks(*)")
        .eq("id", id)
        .single();
      if (error) return json(404, { error: error.message });
      return json(200, data);
    }

    const { data, error } = await supabase
      .from("projects")
      .select("*")
      .order("created_at");
    if (error) return json(500, { error: error.message });
    return json(200, data);
  }

  if (req.method === "POST") {
    const body = await req.json();
    if (!body.name) return json(400, { error: "name required" });

    const { data, error } = await supabase
      .from("projects")
      .insert({ name: body.name, description: body.description })
      .select()
      .single();
    if (error) return json(500, { error: error.message });
    return json(201, data);
  }

  if (req.method === "DELETE" && id) {
    const { error } = await supabase.from("projects").delete().eq("id", id);
    if (error) return json(500, { error: error.message });
    return json(204, {});
  }

  return json(405, { error: "method not allowed" });
};
JS

# ------------------------------------------------------------
# Web React (Redux Toolkit)
# ------------------------------------------------------------
cat > "$BASE/apps/web-react/src/store/store.ts" <<'TS'
import { configureStore } from "@reduxjs/toolkit";
import projects from "../features/projects/projectsSlice";

export const store = configureStore({
  reducer: { projects },
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
TS

cat > "$BASE/apps/web-react/src/features/projects/projectsSlice.ts" <<'TS'
import { createAsyncThunk, createSlice } from "@reduxjs/toolkit";

export const fetchProjects = createAsyncThunk(
  "projects/fetch",
  async () => {
    const res = await fetch("/.netlify/functions/projects");
    return res.json();
  }
);

const slice = createSlice({
  name: "projects",
  initialState: { items: [], status: "idle" },
  reducers: {},
  extraReducers: (b) => {
    b.addCase(fetchProjects.pending, (s) => { s.status = "loading"; })
     .addCase(fetchProjects.fulfilled, (s, a) => {
       s.items = a.payload;
       s.status = "ready";
     });
  },
});

export default slice.reducer;
TS

cat > "$BASE/apps/web-react/src/app/App.tsx" <<'TSX'
import { useEffect } from "react";
import { useDispatch, useSelector } from "react-redux";
import { fetchProjects } from "../features/projects/projectsSlice";

export default function App() {
  const dispatch = useDispatch();
  const projects = useSelector((s: any) => s.projects.items);

  useEffect(() => { dispatch(fetchProjects() as any); }, []);

  return (
    <div>
      <h1>Projects</h1>
      <ul>
        {projects.map((p: any) => <li key={p.id}>{p.name}</li>)}
      </ul>
    </div>
  );
}
TSX

# ------------------------------------------------------------
# React Native (structural parity)
# ------------------------------------------------------------
cat > "$BASE/apps/mobile-react-native/src/store/store.ts" <<'TS'
export { store } from "../../../web-react/src/store/store";
TS

cat > "$BASE/apps/mobile-react-native/src/features/projects/projectsSlice.ts" <<'TS'
export {
  fetchProjects,
  default,
} from "../../../web-react/src/features/projects/projectsSlice";
TS

# ------------------------------------------------------------
# Tauri shell
# ------------------------------------------------------------
cat > "$BASE/apps/desktop-tauri/src/main.ts" <<'TS'
console.log("Tauri desktop shell loaded");
TS

echo
echo "[templates] Templates written successfully."
