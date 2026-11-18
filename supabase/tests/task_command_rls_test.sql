begin;
select plan(20);

select has_table('public', 'workspaces', 'workspaces exists');
select has_table('public', 'workspace_members', 'workspace_members exists');
select has_table('public', 'tasks', 'tasks exists');
select has_table('public', 'task_occurrences', 'task_occurrences exists');
select has_table('public', 'user_settings', 'user_settings exists');
select has_table('public', 'task_reviews', 'task_reviews exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.workspaces'::regclass),
  'workspaces has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.workspace_members'::regclass),
  'workspace_members has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.tasks'::regclass),
  'tasks has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.task_occurrences'::regclass),
  'task_occurrences has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.user_settings'::regclass),
  'user_settings has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.task_reviews'::regclass),
  'task_reviews has RLS enabled'
);

select ok(
  not has_table_privilege('anon', 'public.tasks', 'select,insert,update,delete'),
  'anonymous users have no task privileges'
);
select ok(
  has_table_privilege('authenticated', 'public.tasks', 'select,insert,update,delete'),
  'authenticated role has only policy-controlled task access'
);
select ok(
  not has_table_privilege('anon', 'public.task_reviews', 'select,insert,update'),
  'anonymous users have no review privileges'
);

insert into auth.users (id, aud, role, email)
values
  ('10000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner@example.test'),
  ('20000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'mel@example.test');

insert into public.workspaces (id, name, created_by)
values (
  '30000000-0000-0000-0000-000000000003',
  'Task Command Test',
  '10000000-0000-0000-0000-000000000001'
);

insert into public.workspace_members (workspace_id, user_id, role, display_name)
values
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'owner', 'Owner'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'contributor', 'Mel');

insert into public.tasks (
  id, workspace_id, client_key, name, start_date, start_time, created_by
)
values (
  '40000000-0000-0000-0000-000000000004',
  '30000000-0000-0000-0000-000000000003',
  'owner-task',
  'Owner task',
  current_date,
  '09:00',
  '10000000-0000-0000-0000-000000000001'
);

insert into public.task_occurrences (
  id, task_id, occurrence_date, updated_by
)
values (
  '50000000-0000-0000-0000-000000000005',
  '40000000-0000-0000-0000-000000000004',
  current_date,
  '10000000-0000-0000-0000-000000000001'
);

insert into public.task_reviews (
  occurrence_id, status, requested_by
)
values (
  '50000000-0000-0000-0000-000000000005',
  'ready',
  '10000000-0000-0000-0000-000000000001'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);

select is(
  (select count(*)::integer from public.tasks),
  1,
  'contributor can read workspace tasks'
);

select results_eq(
  $$
    with changed as (
      update public.tasks
      set name = 'Changed by contributor'
      where id = '40000000-0000-0000-0000-000000000004'
      returning id
    )
    select count(*)::bigint from changed
  $$,
  $$ values (0::bigint) $$,
  'contributor cannot edit an owner-created task definition'
);

select lives_ok(
  $$
    insert into public.tasks (
      workspace_id, client_key, name, start_date, start_time, created_by
    )
    values (
      '30000000-0000-0000-0000-000000000003',
      'mel-task',
      'Mel task',
      current_date,
      '10:00',
      '20000000-0000-0000-0000-000000000002'
    )
  $$,
  'contributor can create a task in their workspace'
);

select lives_ok(
  $$
    update public.task_reviews
    set
      status = 'approved',
      note = 'Signed off',
      reviewed_by = '20000000-0000-0000-0000-000000000002',
      reviewed_at = now()
    where occurrence_id = '50000000-0000-0000-0000-000000000005'
  $$,
  'contributor can sign off a submitted review'
);

select is(
  (
    select status
    from public.task_reviews
    where occurrence_id = '50000000-0000-0000-0000-000000000005'
  ),
  'approved',
  'approved review is visible in the workspace'
);

select * from finish();
rollback;
