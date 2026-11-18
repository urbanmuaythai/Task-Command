-- Run only after the Auth users exist. Replace all placeholder UUIDs first.
-- Keep this as a reviewed setup template; it is not an automatic migration.

begin;

insert into public.workspaces (id, name, created_by)
values (
  'REPLACE_WITH_WORKSPACE_UUID'::uuid,
  'Urban Muaythai Task Command',
  'REPLACE_WITH_OWNER_AUTH_USER_UUID'::uuid
);

insert into public.workspace_members (workspace_id, user_id, role, display_name)
values
  (
    'REPLACE_WITH_WORKSPACE_UUID'::uuid,
    'REPLACE_WITH_OWNER_AUTH_USER_UUID'::uuid,
    'owner',
    'Ram'
  ),
  (
    'REPLACE_WITH_WORKSPACE_UUID'::uuid,
    'REPLACE_WITH_MEL_AUTH_USER_UUID'::uuid,
    'contributor',
    'Mel'
  );

commit;
