-- Task Command inside the NMS Supabase project (urban-army-nms, ooxtrhbgsfmpuklbxtqf).
-- 19 Nov 2026: staff sign in with their NMS username + password instead of email links.
--
-- * Tables are prefixed tc_ because NMS already has public.tasks.
-- * Access = an active NMS staff login (public.current_staff_id()) + a row in tc_members.
--   Deactivating someone in NMS Admin > Staff & logins also removes Task Command access.
-- * created_by / updated_by / requested_by / reviewed_by stay Supabase Auth user ids,
--   exactly as the browser app sends them.
-- * Role 'contributor' is shown in the app as "Reviewer" (Mel).

begin;

create table public.tc_workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 100),
  created_at timestamptz not null default now()
);

create table public.tc_members (
  workspace_id uuid not null references public.tc_workspaces(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  role text not null check (role in ('owner', 'contributor')),
  display_name text not null check (char_length(display_name) between 1 and 100),
  created_at timestamptz not null default now(),
  primary key (workspace_id, staff_id)
);

create table public.tc_tasks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.tc_workspaces(id) on delete cascade,
  client_key text not null check (char_length(client_key) between 1 and 100),
  name text not null check (char_length(name) between 1 and 140),
  note text not null default '' check (char_length(note) <= 3000),
  category text not null default 'adhoc' check (char_length(category) <= 50),
  link text check (link is null or link ~ '^https?://'),
  start_date date not null,
  start_time time not null,
  duration_minutes integer not null default 20 check (duration_minutes between 5 and 480),
  priority text not null default 'normal' check (priority in ('normal', 'high')),
  recurrence text not null default 'none'
    check (recurrence in ('none', 'daily', 'weekdays', 'weekly', 'custom')),
  recurrence_days text[] not null default '{}',
  non_negotiable boolean not null default false,
  is_system boolean not null default false,
  created_by uuid not null references auth.users(id) on delete restrict,
  assigned_to uuid references auth.users(id) on delete set null,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, client_key),
  check (recurrence <> 'custom' or cardinality(recurrence_days) > 0),
  check (recurrence_days <@ array['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat']::text[])
);

create table public.tc_task_occurrences (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tc_tasks(id) on delete cascade,
  occurrence_date date not null,
  status text not null default 'todo'
    check (status in ('todo', 'doing', 'waiting', 'done', 'skipped')),
  planned_time time,
  duration_minutes integer not null default 20 check (duration_minutes between 5 and 480),
  priority text not null default 'normal' check (priority in ('normal', 'high')),
  note text not null default '' check (char_length(note) <= 3000),
  gates boolean[] not null default '{}',
  completed_by uuid references auth.users(id) on delete set null,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (task_id, occurrence_date)
);

create table public.tc_task_reviews (
  id uuid primary key default gen_random_uuid(),
  occurrence_id uuid not null unique
    references public.tc_task_occurrences(id) on delete cascade,
  status text not null default 'ready'
    check (status in ('ready', 'changes_requested', 'approved')),
  note text not null default '' check (char_length(note) <= 2000),
  requested_by uuid not null references auth.users(id) on delete restrict,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (status = 'ready' and reviewed_by is null and reviewed_at is null)
    or (status in ('changes_requested', 'approved') and reviewed_by is not null and reviewed_at is not null)
  )
);

create table public.tc_user_settings (
  workspace_id uuid not null references public.tc_workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  workday_start time not null default '09:00',
  workday_end time not null default '18:00',
  break_minutes integer not null default 90 check (break_minutes between 0 and 180),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, user_id),
  check (workday_end > workday_start)
);

create index tc_members_staff_idx on public.tc_members (staff_id, workspace_id);
create index tc_tasks_workspace_active_idx on public.tc_tasks (workspace_id, archived_at, start_date);
create index tc_task_occurrences_date_idx on public.tc_task_occurrences (occurrence_date, task_id);
create index tc_task_reviews_status_idx on public.tc_task_reviews (status, requested_at desc);

-- Role of the signed-in NMS staff member in a workspace (null = no access).
create function public.tc_role(ws uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.role from public.tc_members m
  where m.workspace_id = ws and m.staff_id = public.current_staff_id();
$$;
revoke all on function public.tc_role(uuid) from public;
grant execute on function public.tc_role(uuid) to authenticated;

create function public.tc_task_workspace(t uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select workspace_id from public.tc_tasks where id = t;
$$;
revoke all on function public.tc_task_workspace(uuid) from public;
grant execute on function public.tc_task_workspace(uuid) to authenticated;

create function public.tc_occurrence_workspace(o uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select t.workspace_id from public.tc_task_occurrences o2
  join public.tc_tasks t on t.id = o2.task_id where o2.id = o;
$$;
revoke all on function public.tc_occurrence_workspace(uuid) from public;
grant execute on function public.tc_occurrence_workspace(uuid) to authenticated;

create function public.tc_set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger tc_tasks_set_updated_at before update on public.tc_tasks
  for each row execute function public.tc_set_updated_at();
create trigger tc_task_occurrences_set_updated_at before update on public.tc_task_occurrences
  for each row execute function public.tc_set_updated_at();
create trigger tc_task_reviews_set_updated_at before update on public.tc_task_reviews
  for each row execute function public.tc_set_updated_at();
create trigger tc_user_settings_set_updated_at before update on public.tc_user_settings
  for each row execute function public.tc_set_updated_at();

alter table public.tc_workspaces enable row level security;
alter table public.tc_members enable row level security;
alter table public.tc_tasks enable row level security;
alter table public.tc_task_occurrences enable row level security;
alter table public.tc_task_reviews enable row level security;
alter table public.tc_user_settings enable row level security;

revoke all on table public.tc_workspaces, public.tc_members, public.tc_tasks,
  public.tc_task_occurrences, public.tc_task_reviews, public.tc_user_settings
  from anon, authenticated;
grant select on table public.tc_workspaces, public.tc_members to authenticated;
grant select, insert, update, delete on table public.tc_tasks,
  public.tc_task_occurrences, public.tc_user_settings to authenticated;
grant select, insert, update on table public.tc_task_reviews to authenticated;

-- Workspaces and membership: read your own only. Membership is managed by an admin (SQL).
create policy tc_members_own on public.tc_members for select to authenticated
  using (staff_id = public.current_staff_id());
create policy tc_workspaces_member on public.tc_workspaces for select to authenticated
  using (public.tc_role(id) is not null);

-- Tasks
create policy tc_tasks_read on public.tc_tasks for select to authenticated
  using (public.tc_role(workspace_id) is not null);
create policy tc_tasks_insert on public.tc_tasks for insert to authenticated
  with check (created_by = auth.uid() and public.tc_role(workspace_id) is not null);
create policy tc_tasks_update on public.tc_tasks for update to authenticated
  using (public.tc_role(workspace_id) = 'owner'
         or (public.tc_role(workspace_id) is not null and created_by = auth.uid()))
  with check (public.tc_role(workspace_id) = 'owner'
         or (public.tc_role(workspace_id) is not null and created_by = auth.uid()));
create policy tc_tasks_delete on public.tc_tasks for delete to authenticated
  using (public.tc_role(workspace_id) = 'owner'
         or (public.tc_role(workspace_id) is not null and created_by = auth.uid()));

-- Daily occurrences
create policy tc_occ_read on public.tc_task_occurrences for select to authenticated
  using (public.tc_role(public.tc_task_workspace(task_id)) is not null);
create policy tc_occ_insert on public.tc_task_occurrences for insert to authenticated
  with check (updated_by = auth.uid()
              and public.tc_role(public.tc_task_workspace(task_id)) is not null);
create policy tc_occ_update on public.tc_task_occurrences for update to authenticated
  using (public.tc_role(public.tc_task_workspace(task_id)) is not null)
  with check (updated_by = auth.uid()
              and public.tc_role(public.tc_task_workspace(task_id)) is not null);
create policy tc_occ_delete on public.tc_task_occurrences for delete to authenticated
  using (public.tc_role(public.tc_task_workspace(task_id)) = 'owner'
         or exists (select 1 from public.tc_tasks t where t.id = task_id and t.created_by = auth.uid()
                    and public.tc_role(t.workspace_id) is not null));

-- Mel review workflow
create policy tc_reviews_read on public.tc_task_reviews for select to authenticated
  using (public.tc_role(public.tc_occurrence_workspace(occurrence_id)) is not null);
create policy tc_reviews_request on public.tc_task_reviews for insert to authenticated
  with check (requested_by = auth.uid() and status = 'ready'
              and reviewed_by is null and reviewed_at is null
              and public.tc_role(public.tc_occurrence_workspace(occurrence_id)) is not null);
create policy tc_reviews_resubmit on public.tc_task_reviews for update to authenticated
  using (requested_by = auth.uid() and status = 'changes_requested')
  with check (requested_by = auth.uid() and status = 'ready'
              and reviewed_by is null and reviewed_at is null);
create policy tc_reviews_sign_off on public.tc_task_reviews for update to authenticated
  using (public.tc_role(public.tc_occurrence_workspace(occurrence_id)) = 'contributor')
  with check (reviewed_by = auth.uid() and reviewed_at is not null
              and status in ('changes_requested', 'approved')
              and public.tc_role(public.tc_occurrence_workspace(occurrence_id)) = 'contributor');

-- Personal workday settings
create policy tc_settings_own on public.tc_user_settings for all to authenticated
  using (user_id = auth.uid() and public.tc_role(workspace_id) is not null)
  with check (user_id = auth.uid() and public.tc_role(workspace_id) is not null);

-- Live updates between Ram and Mel
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['tc_tasks', 'tc_task_occurrences', 'tc_task_reviews'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;

-- Same workspace id as before, so supabase-config.js keeps its workspaceId.
insert into public.tc_workspaces (id, name)
values ('2ac84d5d-65c8-494b-8c0f-d5e25b52ff22', 'Urban Muaythai Task Command');

-- Same people and roles as the old project: Ram = owner, Mel = reviewer.
insert into public.tc_members (workspace_id, staff_id, role, display_name)
select '2ac84d5d-65c8-494b-8c0f-d5e25b52ff22', s.id, v.role, v.display_name
from (values ('ram', 'owner', 'Ram'), ('melissa.urban', 'contributor', 'Mel')) v(username, role, display_name)
join public.staff s on s.username = v.username::citext;

commit;
