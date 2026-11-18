# Task Command local and Supabase setup

The app currently runs in **local preview mode**. It keeps the existing browser
backup workflow and enables recurring tasks, selected weekdays, Daily
Non-Negotiables, editing, deletion, and a Mel review/sign-off board without
requiring a cloud connection.

## Review workflow

1. Ram opens a task and selects **Send to Mel**.
2. The task appears under **Mel review → Ready for Mel**.
3. Mel signs in with her approved account and either selects **Approve** or
   adds a note and selects **Request changes**.
4. Ram can resubmit changed work. The Supabase review record retains the
   requester, reviewer, timestamps, outcome, and review note.

When Supabase configuration is present, signed-out visitors see only the login
gate. The task board is revealed after a valid session and an approved
`workspace_members` record are confirmed. Authentication uses a one-time email
link and public sign-up remains disabled.

## Local preview

Serve this directory over HTTP (opening `index.html` directly is not suitable
for email login redirects):

```powershell
python -m http.server 4173
```

Open `http://localhost:4173`.

## Connect a dedicated Supabase project later

1. Create a separate Supabase project for Task Command.
2. Apply both migrations in `supabase/migrations/`, in timestamp order.
3. Create the two approved Auth users in the Supabase dashboard. Public signup
   should remain unavailable to this app; the client requests Magic Links with
   `shouldCreateUser: false`.
4. Use `supabase/bootstrap-example.sql` as a reviewed template to create the
   workspace and add the owner and contributor memberships.
5. Put the project URL, **publishable** browser key, and workspace UUID into
   `supabase-config.js`. Never put a secret key or `service_role` key there.
6. Add the final site URL and local preview URL to Supabase Auth redirect URLs.
7. Configure reliable SMTP before inviting a non-organization email address.

## Access model

- **Owner:** reads and manages every task definition and occurrence.
- **Reviewer (stored as `contributor`):** reads shared tasks, updates shared
  daily occurrences, creates/edits/deletes task definitions they created, and
  approves or requests changes on submitted work.
- **Signed-out visitors:** no database access.

All exposed tables have explicit grants and Row Level Security policies. The
workspace and membership bootstrap is intentionally an administrator action;
the public browser app cannot grant itself access.

## Verification

The RLS test is in `supabase/tests/task_command_rls_test.sql`. Run it after
Docker Desktop is available and the local Supabase stack is started:

```powershell
npx supabase@3.0.0 start
npx supabase@3.0.0 db reset
npx supabase@3.0.0 test db
```

## Vercel preview

The app is buildless and can be deployed directly from this repository. Link
the repository to Vercel, keep the project root at this folder, and deploy a
preview before production. Add both preview and production URLs to the
Supabase Auth redirect allow list before testing email sign-in.

`vercel.json` adds baseline browser security headers. Supabase connection
values remain in `supabase-config.js`; only the project URL, publishable key,
and workspace UUID belong there.
