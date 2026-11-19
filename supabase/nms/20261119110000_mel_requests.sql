-- Mel Review requests (19 Nov 2026).
-- Mel (or Ram) adds a request; Ram posts progress updates and status; Mel signs it off.
-- Not tied to a day of the week. Runs in the NMS project after 20261119090000_task_command_tables.sql.

begin;

create table public.tc_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.tc_workspaces(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 160),
  details text not null default '' check (char_length(details) <= 4000),
  link text check (link is null or link ~ '^https?://'),
  priority text not null default 'normal' check (priority in ('normal', 'high')),
  due_date date,
  status text not null default 'todo'
    check (status in ('todo', 'doing', 'waiting', 'review', 'done')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_by_name text not null check (char_length(created_by_name) between 1 and 100),
  last_update text not null default '' check (char_length(last_update) <= 2000),
  last_update_by_name text not null default '',
  last_update_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tc_request_updates (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.tc_requests(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete restrict,
  author_name text not null check (char_length(author_name) between 1 and 100),
  status text check (status in ('todo', 'doing', 'waiting', 'review', 'done')),
  note text not null default '' check (char_length(note) <= 2000),
  created_at timestamptz not null default now()
);

create index tc_requests_workspace_idx on public.tc_requests (workspace_id, status, updated_at desc);
create index tc_request_updates_request_idx on public.tc_request_updates (request_id, created_at);

create trigger tc_requests_set_updated_at before update on public.tc_requests
  for each row execute function public.tc_set_updated_at();

create function public.tc_request_workspace(r uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select workspace_id from public.tc_requests where id = r;
$$;
revoke all on function public.tc_request_workspace(uuid) from public;
grant execute on function public.tc_request_workspace(uuid) to authenticated;

alter table public.tc_requests enable row level security;
alter table public.tc_request_updates enable row level security;
revoke all on table public.tc_requests, public.tc_request_updates from anon, authenticated;
grant select, insert, update, delete on table public.tc_requests to authenticated;
grant select, insert on table public.tc_request_updates to authenticated;

-- Everyone in the workspace sees every request and its history.
create policy tc_requests_read on public.tc_requests for select to authenticated
  using (public.tc_role(workspace_id) is not null);
create policy tc_requests_insert on public.tc_requests for insert to authenticated
  with check (created_by = auth.uid() and public.tc_role(workspace_id) is not null);
-- Both sides move requests along (Ram: progress; Mel: sign-off / edits).
create policy tc_requests_update on public.tc_requests for update to authenticated
  using (public.tc_role(workspace_id) is not null)
  with check (public.tc_role(workspace_id) is not null);
-- Only the person who added it (or the owner) can delete it.
create policy tc_requests_delete on public.tc_requests for delete to authenticated
  using (created_by = auth.uid() or public.tc_role(workspace_id) = 'owner');

-- Update history is add-only.
create policy tc_request_updates_read on public.tc_request_updates for select to authenticated
  using (public.tc_role(public.tc_request_workspace(request_id)) is not null);
create policy tc_request_updates_insert on public.tc_request_updates for insert to authenticated
  with check (author_id = auth.uid()
              and public.tc_role(public.tc_request_workspace(request_id)) is not null);

do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['tc_requests', 'tc_request_updates'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;

commit;
