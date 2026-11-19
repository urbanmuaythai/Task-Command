(() => {
  "use strict";

  const config = window.TASK_COMMAND_SUPABASE || {};
  const accountButton = document.getElementById("accountButton");
  const accountCopy = document.getElementById("accountCopy");
  const authDialog = document.getElementById("authDialog");
  const authForm = document.getElementById("authForm");
  const authStatus = document.getElementById("authStatus");
  const loginGate = document.getElementById("loginGate");
  const loginForm = document.getElementById("loginForm");
  const loginStatus = document.getElementById("loginStatus");
  const syncBanner = document.getElementById("syncBanner");
  const syncState = document.getElementById("syncState");
  const originalSave = save;
  const api = {
    configured: false,
    connected: false,
    role: "local",
    userId: "",
    deleteTask: async () => {},
    saveReview: async () => {},
  };
  window.TaskCommandCloud = api;

  let client = null;
  let currentUser = null;
  let membership = null;
  let taskIds = new Map();
  let occurrenceIds = new Map();
  let syncTimer = null;
  let reloadTimer = null;
  let syncing = false;
  let applyingRemote = false;
  let lastPayload = "";
  let realtimeChannel = null;

  function setStatus(message, mode = "local") {
    syncState.textContent = message;
    syncBanner.dataset.mode = mode;
  }

  function setLocalUi(message = "Not connected") {
    accountCopy.innerHTML =
      "<strong>Local preview</strong>Browser-only storage";
    accountButton.textContent = "Connect";
    setStatus(message, "local");
  }

  function setLoginGate(visible, message = "") {
    loginGate.hidden = !visible;
    document.body.classList.toggle("auth-locked", visible);
    loginStatus.textContent = message;
  }

  function setSignedInUi() {
    const name =
      membership?.display_name || currentUser?.email || "Team member";
    accountCopy.innerHTML = `<strong>${esc(name)}</strong>${esc(membership.role === "owner" ? "Owner" : "Reviewer")}`;
    accountButton.textContent = "Sign out";
    setLoginGate(false);
    setStatus("Cloud connected", "connected");
    document.getElementById("storageNote").textContent =
      "Saved locally and synced to the shared Task Command workspace.";
  }

  function configured() {
    return Boolean(
      config.url &&
      config.publishableKey &&
      config.workspaceId &&
      window.supabase?.createClient,
    );
  }

  if (!configured()) {
    setLoginGate(false);
    setLocalUi("Supabase setup pending");
    authStatus.textContent =
      "The local Supabase configuration is not connected yet. You can continue testing in local preview mode.";
    accountButton.onclick = () => authDialog.showModal();
    return;
  }

  api.configured = true;
  setLoginGate(true);
  client = window.supabase.createClient(config.url, config.publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });

  function canWriteTask(task) {
    return (
      membership?.role === "owner" ||
      !task.createdBy ||
      task.createdBy === api.userId
    );
  }

  function taskRow(task) {
    const system = Boolean(DATA.tasks[task.id]);
    return {
      workspace_id: config.workspaceId,
      client_key: task.id,
      name: task.name,
      note: task.note || "",
      category: task.cat || "adhoc",
      link: safeUrl(task.link || link(task.id) || "") || null,
      start_date: system ? "2020-01-01" : task.date,
      start_time: task.time,
      duration_minutes: task.duration,
      priority: task.priority === "high" ? "high" : "normal",
      recurrence: system ? "custom" : task.recurrence || "none",
      recurrence_days: system ? task.days : task.days || [],
      non_negotiable: Boolean(task.nonNegotiable),
      is_system: system,
      created_by: task.createdBy || api.userId,
      updated_at: new Date().toISOString(),
    };
  }

  function occurrenceRow(record) {
    const taskId = taskIds.get(record.id);
    if (!taskId) return null;
    return {
      task_id: taskId,
      occurrence_date: record.date,
      status: statuses.includes(record.status) ? record.status : "todo",
      planned_time: validTime(record.time) ? record.time : null,
      duration_minutes: Math.max(
        5,
        Math.min(480, Number(record.duration) || 20),
      ),
      priority: record.priority === "high" ? "high" : "normal",
      note: String(record.note || "").slice(0, 3000),
      gates: Array.isArray(record.gates) ? record.gates.map(Boolean) : [],
      updated_by: api.userId,
      updated_at: new Date().toISOString(),
    };
  }

  function sharedPayload() {
    return JSON.stringify({
      personal: db.personal,
      records: db.records,
      settings: db.settings,
      links: db.links,
    });
  }

  function queueSync() {
    if (!api.connected || applyingRemote) return;
    clearTimeout(syncTimer);
    syncTimer = setTimeout(syncToCloud, 700);
  }

  save = function saveWithCloudSync() {
    originalSave();
    queueSync();
  };

  async function upsertTasks() {
    const rows = [];
    if (membership.role === "owner") {
      for (const task of Object.values(DATA.tasks)) rows.push(taskRow(task));
    }
    for (const task of db.personal) {
      if (!task.createdBy) task.createdBy = api.userId;
      if (canWriteTask(task)) rows.push(taskRow(task));
    }
    if (rows.length) {
      const { error } = await client
        .from("tc_tasks")
        .upsert(rows, { onConflict: "workspace_id,client_key" });
      if (error) throw error;
    }
    const { data, error } = await client
      .from("tc_tasks")
      .select("id,client_key")
      .eq("workspace_id", config.workspaceId)
      .is("archived_at", null);
    if (error) throw error;
    taskIds = new Map((data || []).map((row) => [row.client_key, row.id]));
  }

  async function syncToCloud() {
    if (!api.connected || syncing) return;
    const payload = sharedPayload();
    if (payload === lastPayload) return;
    syncing = true;
    setStatus("Syncing…", "syncing");
    try {
      await upsertTasks();
      const occurrences = Object.values(db.records)
        .map(occurrenceRow)
        .filter(Boolean);
      for (let i = 0; i < occurrences.length; i += 250) {
        const { error } = await client
          .from("tc_task_occurrences")
          .upsert(occurrences.slice(i, i + 250), {
            onConflict: "task_id,occurrence_date",
          });
        if (error) throw error;
      }
      const { error: settingsError } = await client
        .from("tc_user_settings")
        .upsert(
          {
            workspace_id: config.workspaceId,
            user_id: api.userId,
            workday_start: db.settings.start,
            workday_end: db.settings.end,
            break_minutes: db.settings.breakMinutes,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "workspace_id,user_id" },
        );
      if (settingsError) throw settingsError;
      lastPayload = sharedPayload();
      setStatus("Saved", "connected");
    } catch (error) {
      console.error("Task Command sync failed", error);
      setStatus("Sync needs attention", "error");
      notify(error.message || "Unable to sync Task Command.");
    } finally {
      syncing = false;
    }
  }

  async function loadWorkspace() {
    if (!currentUser) return;
    setStatus("Loading workspace…", "syncing");
    const { data: member, error: memberError } = await client
      .from("tc_members")
      .select("workspace_id,role,display_name")
      .eq("workspace_id", config.workspaceId)
      .maybeSingle(); // RLS only returns the signed-in staff member's own row
    if (memberError) throw memberError;
    if (!member) {
      membership = null;
      api.connected = false;
      accountCopy.innerHTML = `<strong>${esc(currentUser.email || "Signed in")}</strong>No workspace access`;
      accountButton.textContent = "Sign out";
      setStatus("Access not approved", "error");
      setLoginGate(
        true,
        "This account is signed in but has not been approved for this workspace.",
      );
      notify("This account has not been added to the Task Command workspace.");
      return;
    }
    membership = member;
    api.connected = true;
    api.role = member.role;
    api.userId = currentUser.id;
    setSignedInUi();

    const { data: tasks, error: taskError } = await client
      .from("tc_tasks")
      .select(
        "id,client_key,name,note,category,link,start_date,start_time,duration_minutes,priority,recurrence,recurrence_days,non_negotiable,is_system,created_by,assigned_to",
      )
      .eq("workspace_id", config.workspaceId)
      .is("archived_at", null);
    if (taskError) throw taskError;
    taskIds = new Map((tasks || []).map((row) => [row.client_key, row.id]));

    applyingRemote = true;
    try {
      for (const row of tasks || []) {
        if (row.is_system) continue;
        const local = db.personal.find((task) => task.id === row.client_key);
        const mapped = {
          id: row.client_key,
          name: row.name,
          cat: row.category || "adhoc",
          date: row.start_date,
          time: row.start_time,
          duration: row.duration_minutes,
          priority: row.priority,
          note: row.note || "",
          link: row.link || "",
          recurrence: row.recurrence || "none",
          days: row.recurrence_days || [],
          nonNegotiable: Boolean(row.non_negotiable),
          createdBy: row.created_by,
          assignedTo: row.assigned_to || "",
        };
        if (local) Object.assign(local, mapped);
        else db.personal.push(mapped);
      }

      const ids = (tasks || []).map((row) => row.id);
      if (ids.length) {
        const { data: occurrences, error: occurrenceError } = await client
          .from("tc_task_occurrences")
          .select(
            "id,task_id,occurrence_date,status,planned_time,duration_minutes,priority,note,gates",
          )
          .in("task_id", ids);
        if (occurrenceError) throw occurrenceError;
        const keysById = new Map(
          (tasks || []).map((row) => [row.id, row.client_key]),
        );
        occurrenceIds = new Map();
        for (const row of occurrences || []) {
          const clientKey = keysById.get(row.task_id);
          if (!clientKey) continue;
          occurrenceIds.set(`${row.occurrence_date}:${clientKey}`, row.id);
          db.records[`${row.occurrence_date}:${clientKey}`] = {
            date: row.occurrence_date,
            id: clientKey,
            status: row.status,
            time: row.planned_time || undefined,
            duration: row.duration_minutes,
            priority: row.priority,
            note: row.note || "",
            gates: row.gates || [],
          };
        }

        const occurrenceIdList = (occurrences || []).map((row) => row.id);
        if (occurrenceIdList.length) {
          const { data: reviews, error: reviewError } = await client
            .from("tc_task_reviews")
            .select(
              "occurrence_id,status,note,requested_by,requested_at,reviewed_by,reviewed_at",
            )
            .in("occurrence_id", occurrenceIdList);
          if (reviewError) throw reviewError;
          const recordKeysByOccurrence = new Map(
            Array.from(occurrenceIds, ([key, id]) => [id, key]),
          );
          for (const review of reviews || []) {
            const recordKey = recordKeysByOccurrence.get(review.occurrence_id);
            const record = recordKey ? db.records[recordKey] : null;
            if (!record) continue;
            record.review = {
              status: review.status,
              note: review.note || "",
              requestedBy: review.requested_by,
              requestedAt: review.requested_at,
              reviewedBy: review.reviewed_by || "",
              reviewedAt: review.reviewed_at || "",
            };
          }
        }
      }

      const { data: settings, error: settingsError } = await client
        .from("tc_user_settings")
        .select("workday_start,workday_end,break_minutes")
        .eq("workspace_id", config.workspaceId)
        .eq("user_id", api.userId)
        .maybeSingle();
      if (settingsError) throw settingsError;
      if (settings) {
        db.settings = {
          start: settings.workday_start.slice(0, 5),
          end: settings.workday_end.slice(0, 5),
          breakMinutes: settings.break_minutes,
        };
      }
      originalSave();
      render();
      lastPayload = "";
    } finally {
      applyingRemote = false;
    }

    await syncToCloud();
    subscribeToWorkspace();
  }

  function queueReload() {
    if (!api.connected || syncing) return;
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(() => loadWorkspace().catch(handleError), 800);
  }

  function subscribeToWorkspace() {
    if (realtimeChannel) client.removeChannel(realtimeChannel);
    realtimeChannel = client
      .channel(`task-command-${config.workspaceId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "tc_tasks" },
        queueReload,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "tc_task_occurrences" },
        queueReload,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "tc_task_reviews" },
        queueReload,
      )
      .subscribe();
  }

  function handleError(error) {
    console.error("Task Command cloud error", error);
    setStatus("Cloud connection error", "error");
    notify(error.message || "Unable to load the shared workspace.");
  }

  api.deleteTask = async (clientKey) => {
    if (!api.connected) return;
    const id = taskIds.get(clientKey);
    if (!id) return;
    const { error } = await client.from("tc_tasks").delete().eq("id", id);
    if (error) {
      notify(error.message || "You cannot delete this task.");
      throw error;
    }
    taskIds.delete(clientKey);
  };

  api.saveReview = async (record, status, note = "") => {
    if (!api.connected) return;
    await syncToCloud();
    const taskId = taskIds.get(record.id);
    if (!taskId) throw Error("This task has not synced yet.");

    const recordKey = `${record.date}:${record.id}`;
    let occurrenceId = occurrenceIds.get(recordKey);
    if (!occurrenceId) {
      const { data, error } = await client
        .from("tc_task_occurrences")
        .select("id")
        .eq("task_id", taskId)
        .eq("occurrence_date", record.date)
        .maybeSingle();
      if (error) throw error;
      occurrenceId = data?.id;
      if (occurrenceId) occurrenceIds.set(recordKey, occurrenceId);
    }
    if (!occurrenceId) throw Error("Save the task before requesting review.");

    const now = new Date().toISOString();
    const existing = record.review || {};
    const requestRow = {
      occurrence_id: occurrenceId,
      status,
      note: String(note || "").slice(0, 2000),
      requested_by:
        status === "ready" ? api.userId : existing.requestedBy || "",
      requested_at: status === "ready" ? now : existing.requestedAt || now,
      reviewed_by: status === "ready" ? null : api.userId,
      reviewed_at: status === "ready" ? null : now,
    };

    const query = existing.status && existing.status !== "not_requested"
      ? client
          .from("tc_task_reviews")
          .update(requestRow)
          .eq("occurrence_id", occurrenceId)
      : client.from("tc_task_reviews").insert(requestRow);
    const { error } = await query;
    if (error) throw error;
    setStatus("Review saved", "connected");
  };

  accountButton.onclick = async () => {
    if (currentUser) {
      await client.auth.signOut();
      return;
    }
    authStatus.textContent = "";
    authDialog.showModal();
  };

  // Same logins as the NMS app: "<username>@staff.urbanmuaythai.com" in Supabase Auth.
  function loginEmail(username) {
    const value = username.trim().toLowerCase();
    return value.includes("@") ? value : `${value}@staff.urbanmuaythai.com`;
  }

  async function signIn(form, statusElement, event) {
    event.preventDefault();
    const username = form.elements.username.value;
    const password = form.elements.password.value;
    statusElement.textContent = "Signing in…";
    const { error } = await client.auth.signInWithPassword({
      email: loginEmail(username),
      password,
    });
    form.elements.password.value = "";
    if (error) {
      statusElement.textContent = /invalid/i.test(error.message)
        ? "Wrong username or password. Use the same login as the NMS app."
        : error.message;
      return;
    }
    statusElement.textContent = "";
    if (form === authForm) authDialog.close();
  }

  authForm.onsubmit = (event) => signIn(authForm, authStatus, event);
  loginForm.onsubmit = (event) => signIn(loginForm, loginStatus, event);

  client.auth.onAuthStateChange((_event, session) => {
    currentUser = session?.user || null;
    if (!currentUser) {
      membership = null;
      api.connected = false;
      api.role = "local";
      api.userId = "";
      if (realtimeChannel) client.removeChannel(realtimeChannel);
      realtimeChannel = null;
      setLocalUi("Signed out · local preview");
      setLoginGate(true);
      return;
    }
    loadWorkspace().catch(handleError);
  });

  client.auth.getSession().then(({ data, error }) => {
    if (error) return handleError(error);
    currentUser = data.session?.user || null;
    if (currentUser) loadWorkspace().catch(handleError);
    else {
      setLocalUi("Ready to sign in");
      setLoginGate(true);
    }
  });
})();
