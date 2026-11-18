create extension if not exists pgcrypto with schema extensions;

create table public.workspaces (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 100),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'contributor')),
  display_name text not null check (char_length(display_name) between 1 and 100),
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create table public.tasks (
  id uuid primary key default extensions.gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
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

create table public.task_occurrences (
  id uuid primary key default extensions.gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
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

create table public.user_settings (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  workday_start time not null default '09:00',
  workday_end time not null default '18:00',
  break_minutes integer not null default 90 check (break_minutes between 0 and 180),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, user_id),
  check (workday_end > workday_start)
);

create index workspace_members_user_idx
  on public.workspace_members (user_id, workspace_id);
create index tasks_workspace_active_idx
  on public.tasks (workspace_id, archived_at, start_date);
create index task_occurrences_date_idx
  on public.task_occurrences (occurrence_date, task_id);

create function public.set_task_command_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function public.set_task_command_updated_at() from public;
grant execute on function public.set_task_command_updated_at() to authenticated;

create trigger tasks_set_updated_at
before update on public.tasks
for each row execute function public.set_task_command_updated_at();

create trigger task_occurrences_set_updated_at
before update on public.task_occurrences
for each row execute function public.set_task_command_updated_at();

create trigger user_settings_set_updated_at
before update on public.user_settings
for each row execute function public.set_task_command_updated_at();

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.tasks enable row level security;
alter table public.task_occurrences enable row level security;
alter table public.user_settings enable row level security;

revoke all on table public.workspaces from anon, authenticated;
revoke all on table public.workspace_members from anon, authenticated;
revoke all on table public.tasks from anon, authenticated;
revoke all on table public.task_occurrences from anon, authenticated;
revoke all on table public.user_settings from anon, authenticated;

grant select on table public.workspaces to authenticated;
grant select on table public.workspace_members to authenticated;
grant select, insert, update, delete on table public.tasks to authenticated;
grant select, insert, update, delete on table public.task_occurrences to authenticated;
grant select, insert, update, delete on table public.user_settings to authenticated;

create policy "Members can view their own membership"
on public.workspace_members
for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Members can view their workspace"
on public.workspaces
for select
to authenticated
using (
  exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = workspaces.id
      and member.user_id = (select auth.uid())
  )
);

create policy "Members can view workspace tasks"
on public.tasks
for select
to authenticated
using (
  exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = tasks.workspace_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Members can create their own tasks"
on public.tasks
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = tasks.workspace_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Owners or creators can update tasks"
on public.tasks
for update
to authenticated
using (
  exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = tasks.workspace_id
      and member.user_id = (select auth.uid())
      and (member.role = 'owner' or tasks.created_by = (select auth.uid()))
  )
)
with check (
  exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = tasks.workspace_id
      and member.user_id = (select auth.uid())
      and (member.role = 'owner' or tasks.created_by = (select auth.uid()))
  )
);

create policy "Owners or creators can delete tasks"
on public.tasks
for delete
to authenticated
using (
  exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = tasks.workspace_id
      and member.user_id = (select auth.uid())
      and (member.role = 'owner' or tasks.created_by = (select auth.uid()))
  )
);

create policy "Members can view task occurrences"
on public.task_occurrences
for select
to authenticated
using (
  exists (
    select 1
    from public.tasks task
    join public.workspace_members member
      on member.workspace_id = task.workspace_id
    where task.id = task_occurrences.task_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Members can create task occurrences"
on public.task_occurrences
for insert
to authenticated
with check (
  updated_by = (select auth.uid())
  and exists (
    select 1
    from public.tasks task
    join public.workspace_members member
      on member.workspace_id = task.workspace_id
    where task.id = task_occurrences.task_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Members can update task occurrences"
on public.task_occurrences
for update
to authenticated
using (
  exists (
    select 1
    from public.tasks task
    join public.workspace_members member
      on member.workspace_id = task.workspace_id
    where task.id = task_occurrences.task_id
      and member.user_id = (select auth.uid())
  )
)
with check (
  updated_by = (select auth.uid())
  and exists (
    select 1
    from public.tasks task
    join public.workspace_members member
      on member.workspace_id = task.workspace_id
    where task.id = task_occurrences.task_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Owners or task creators can delete occurrences"
on public.task_occurrences
for delete
to authenticated
using (
  exists (
    select 1
    from public.tasks task
    join public.workspace_members member
      on member.workspace_id = task.workspace_id
    where task.id = task_occurrences.task_id
      and member.user_id = (select auth.uid())
      and (member.role = 'owner' or task.created_by = (select auth.uid()))
  )
);

create policy "Users can view their settings"
on public.user_settings
for select
to authenticated
using (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = user_settings.workspace_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Users can create their settings"
on public.user_settings
for insert
to authenticated
with check (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = user_settings.workspace_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Users can update their settings"
on public.user_settings
for update
to authenticated
using (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = user_settings.workspace_id
      and member.user_id = (select auth.uid())
  )
)
with check (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = user_settings.workspace_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Users can delete their settings"
on public.user_settings
for delete
to authenticated
using (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.workspace_members member
    where member.workspace_id = user_settings.workspace_id
      and member.user_id = (select auth.uid())
  )
);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'tasks'
    ) then
      alter publication supabase_realtime add table public.tasks;
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'task_occurrences'
    ) then
      alter publication supabase_realtime add table public.task_occurrences;
    end if;
  end if;
end;
$$;
