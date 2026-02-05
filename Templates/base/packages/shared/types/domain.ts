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
