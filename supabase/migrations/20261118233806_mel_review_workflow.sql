create table public.task_reviews (
  id uuid primary key default extensions.gen_random_uuid(),
  occurrence_id uuid not null unique
    references public.task_occurrences(id) on delete cascade,
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

create index task_reviews_status_idx
  on public.task_reviews (status, requested_at desc);

create trigger task_reviews_set_updated_at
before update on public.task_reviews
for each row execute function public.set_task_command_updated_at();

alter table public.task_reviews enable row level security;

revoke all on table public.task_reviews from anon, authenticated;
grant select, insert, update on table public.task_reviews to authenticated;

create policy "Members can view workspace reviews"
on public.task_reviews
for select
to authenticated
using (
  exists (
    select 1
    from public.task_occurrences occurrence
    join public.tasks task on task.id = occurrence.task_id
    join public.workspace_members member on member.workspace_id = task.workspace_id
    where occurrence.id = task_reviews.occurrence_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Members can request a review"
on public.task_reviews
for insert
to authenticated
with check (
  requested_by = (select auth.uid())
  and status = 'ready'
  and reviewed_by is null
  and reviewed_at is null
  and exists (
    select 1
    from public.task_occurrences occurrence
    join public.tasks task on task.id = occurrence.task_id
    join public.workspace_members member on member.workspace_id = task.workspace_id
    where occurrence.id = task_reviews.occurrence_id
      and member.user_id = (select auth.uid())
  )
);

create policy "Requesters can resubmit changes"
on public.task_reviews
for update
to authenticated
using (
  requested_by = (select auth.uid())
  and status = 'changes_requested'
)
with check (
  requested_by = (select auth.uid())
  and status = 'ready'
  and reviewed_by is null
  and reviewed_at is null
);

create policy "Contributors can sign off reviews"
on public.task_reviews
for update
to authenticated
using (
  exists (
    select 1
    from public.task_occurrences occurrence
    join public.tasks task on task.id = occurrence.task_id
    join public.workspace_members member on member.workspace_id = task.workspace_id
    where occurrence.id = task_reviews.occurrence_id
      and member.user_id = (select auth.uid())
      and member.role = 'contributor'
  )
)
with check (
  reviewed_by = (select auth.uid())
  and reviewed_at is not null
  and status in ('changes_requested', 'approved')
  and exists (
    select 1
    from public.task_occurrences occurrence
    join public.tasks task on task.id = occurrence.task_id
    join public.workspace_members member on member.workspace_id = task.workspace_id
    where occurrence.id = task_reviews.occurrence_id
      and member.user_id = (select auth.uid())
      and member.role = 'contributor'
  )
);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'task_reviews'
    ) then
      alter publication supabase_realtime add table public.task_reviews;
    end if;
  end if;
end;
$$;
