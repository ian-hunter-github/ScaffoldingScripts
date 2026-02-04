insert into public.projects (name) values
  ('Demo Project A'),
  ('Demo Project B')
on conflict do nothing;

insert into public.tasks (project_id, title, done)
select p.id, t.title, t.done
from public.projects p
join (values
  ('Demo Task 1', false),
  ('Demo Task 2', true),
  ('Demo Task 3', false)
) as t(title, done) on true
where p.name = 'Demo Project A';

insert into public.tasks (project_id, title, done)
select p.id, t.title, t.done
from public.projects p
join (values
  ('Another Task 1', false),
  ('Another Task 2', false)
) as t(title, done) on true
where p.name = 'Demo Project B';
