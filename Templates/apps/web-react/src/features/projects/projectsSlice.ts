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
