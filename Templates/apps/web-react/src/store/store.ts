import { configureStore } from "@reduxjs/toolkit";
import projects from "../features/projects/projectsSlice";

export const store = configureStore({
  reducer: { projects },
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
