(() => {
  const params = new URLSearchParams(window.location.search);
  const storedToken = (() => {
    try { return sessionStorage.getItem("proxycat-web-token") || ""; } catch { return ""; }
  })();
  let token = params.get("token") || storedToken || "";
  let profiles = [];
  let current = null; // {id, name, yaml}
  let dirty = false;
  // Counts overlapping async operations (save, profile load, delete).
  // While nonzero, editable controls and profile navigation are locked so
  // keystrokes can't be discarded by a response that reloads the editor.
  let busyCount = 0;
  let profileRequestId = 0;
  let profilesRequestId = 0;

  const $ = (id) => document.getElementById(id);
  const statusDot = $("statusDot");
  const statusText = $("statusText");
  const list = $("profileList");
  const emptyState = $("emptyState");
  const authPane = $("authPane");
  const editorPane = $("editor");
  const nameInput = $("nameInput");
  const yamlInput = $("yamlInput");
  const saveBtn = $("saveBtn");
  const activateBtn = $("activateBtn");
  const deleteBtn = $("deleteBtn");
  const newBtn = $("newBtn");
  const refreshBtn = $("refreshBtn");
  const toast = $("toast");

  function setStatus(text, ok) {
    statusText.textContent = text;
    statusDot.className = "dot" + (ok === true ? " ok" : ok === false ? " bad" : "");
  }

  function showToast(message, isError = false) {
    toast.textContent = message;
    toast.className = "show" + (isError ? " error" : "");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => {
      toast.className = isError ? "error" : "";
    }, 2600);
  }

  function setDirty(value) {
    dirty = value;
    $("hint").textContent = value
      ? "Unsaved changes. Save validates the full YAML with mihomo."
      : "Save validates the full YAML with mihomo.";
    $("hint").style.color = value ? "var(--danger)" : "";
  }

  function showAuth() {
    authPane.hidden = false;
    editorPane.hidden = true;
    emptyState.hidden = true;
    setStatus("Token required", false);
  }

  function showEditor() {
    authPane.hidden = true;
    emptyState.hidden = true;
    editorPane.hidden = false;
  }

  function updateButtons() {
    const busy = busyCount > 0;
    activateBtn.disabled = busy || !current;
    deleteBtn.disabled = busy || !current;
    saveBtn.disabled = busy || !nameInput.value.trim() || !yamlInput.value.trim();
  }

  function setBusy(delta) {
    busyCount = Math.max(0, busyCount + delta);
    const busy = busyCount > 0;
    nameInput.disabled = busy;
    yamlInput.disabled = busy;
    newBtn.disabled = busy;
    refreshBtn.disabled = busy;
    updateButtons();
  }

  async function api(path, options = {}) {
    if (!token) {
      showAuth();
      throw new Error("Access token required");
    }
    const headers = Object.assign({}, options.headers, {
      "Authorization": "Bearer " + token
    });
    const response = await fetch(path, Object.assign({}, options, { headers }));
    if (response.status === 401) {
      showAuth();
      throw new Error("Invalid or expired token");
    }
    if (!response.ok) {
      let message = "HTTP " + response.status;
      try {
        const body = await response.json();
        if (body && body.error) message = body.error;
      } catch { /* ignore */ }
      throw new Error(message);
    }
    if (response.status === 204) return null;
    const type = response.headers.get("content-type") || "";
    return type.includes("application/json") ? response.json() : response.text();
  }

  function renderProfiles() {
    list.replaceChildren();
    for (const profile of profiles) {
      const item = document.createElement("li");
      item.className = profile.isActive ? "active" : "";
      item.dataset.id = profile.id;
      item.addEventListener("click", () => {
        if (busyCount > 0) return;
        loadProfile(profile.id).catch((error) => showToast(error.message, true));
      });

      const name = document.createElement("span");
      name.className = "profile-name";
      name.textContent = profile.name;

      const meta = document.createElement("span");
      meta.className = "profile-meta";
      meta.textContent = profile.isActive
        ? "Active" + (profile.hasRemote ? " · Remote" : "")
        : (profile.hasRemote ? "Remote" : "Local");

      item.append(name, meta);
      list.append(item);
    }
  }

  async function loadProfiles(selectId) {
    const requestId = ++profilesRequestId;
    const loaded = await api("/api/profiles");
    // A newer refresh already rendered; never let a slow older response
    // overwrite it.
    if (requestId !== profilesRequestId) return;
    profiles = loaded;
    renderProfiles();
    setStatus(
      profiles.length ? profiles.length + " profile" + (profiles.length === 1 ? "" : "s") : "No profiles",
      true
    );
    const candidates = [
      selectId,
      current && current.id,
      (profiles.find((p) => p.isActive) || profiles[0] || {}).id,
    ];
    const wanted = candidates.find((id) => id && profiles.some((p) => p.id === id));
    if (wanted) {
      await loadProfile(wanted);
    } else {
      current = null;
      editorPane.hidden = true;
      emptyState.hidden = false;
      // A successful API call means the token is valid, so the login
      // prompt must not linger next to the empty state.
      authPane.hidden = true;
      updateButtons();
    }
  }

  async function loadProfile(id) {
    if (dirty && !confirm("Discard unsaved changes?")) return;
    const requestId = ++profileRequestId;
    setBusy(1);
    try {
      const detail = await api("/api/profiles/" + encodeURIComponent(id));
      // A later click (or New/Delete) superseded this read; drop it
      // instead of replacing the newer selection.
      if (requestId !== profileRequestId) return;
      current = detail;
      nameInput.value = detail.name;
      yamlInput.value = detail.yaml;
      setDirty(false);
      renderProfiles();
      showEditor();
      setStatus("Editing " + detail.name, true);
    } finally {
      setBusy(-1);
    }
  }

  async function save() {
    if (busyCount > 0) return;
    const name = nameInput.value.trim();
    const yaml = yamlInput.value;
    if (!name) { showToast("Profile name cannot be empty", true); return; }
    if (!yaml.trim()) { showToast("YAML cannot be empty", true); return; }

    const savedId = current && current.id ? current.id : null;
    setBusy(1);
    try {
      if (savedId) {
        current = await api("/api/profiles/" + encodeURIComponent(savedId), {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, yaml })
        });
      } else {
        current = await api("/api/profiles", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, yaml })
        });
      }
      const targetId = savedId || current.id;
      // The fields are locked while the request is in flight, but verify
      // anyway: if anything changed the text, reloading from the server
      // would silently throw those edits away.
      if (nameInput.value.trim() === name && yamlInput.value === yaml) {
        setDirty(false);
        showToast("Saved");
        await loadProfiles(targetId);
      } else {
        showToast("Saved; newer edits are kept");
      }
    } catch (error) {
      showToast(error.message, true);
    } finally {
      setBusy(-1);
    }
  }

  async function activate() {
    if (busyCount > 0 || !current) return;
    const id = current.id;
    setBusy(1);
    try {
      await api("/api/profiles/" + encodeURIComponent(id) + "/activate", { method: "POST" });
      showToast("Activated");
      await loadProfiles(id);
    } catch (error) {
      showToast(error.message, true);
    } finally {
      setBusy(-1);
    }
  }

  async function remove() {
    if (busyCount > 0 || !current) return;
    if (!confirm("Delete profile \"" + current.name + "\"?")) return;
    const id = current.id;
    setBusy(1);
    try {
      await api("/api/profiles/" + encodeURIComponent(id), { method: "DELETE" });
      current = null;
      profileRequestId += 1; // ignore any detail read still in flight
      setDirty(false);
      showToast("Deleted");
      await loadProfiles();
    } catch (error) {
      showToast(error.message, true);
    } finally {
      setBusy(-1);
    }
  }

  async function createNew() {
    if (busyCount > 0) return;
    if (dirty && !confirm("Discard unsaved changes?")) return;
    setBusy(1);
    try {
      const template = await api("/api/default-profile");
      profileRequestId += 1; // ignore any detail read still in flight
      current = null;
      nameInput.value = "New Profile";
      yamlInput.value = template.yaml;
      setDirty(true);
      editorPane.hidden = false;
      emptyState.hidden = true;
      authPane.hidden = true;
      setStatus("New profile", true);
    } catch (error) {
      showToast(error.message, true);
    } finally {
      setBusy(-1);
    }
  }

  async function refresh() {
    if (busyCount > 0) return;
    try {
      await loadProfiles();
    } catch (error) {
      showToast(error.message, true);
    }
  }

  async function boot() {
    if (!token) { showAuth(); return; }
    try {
      try { sessionStorage.setItem("proxycat-web-token", token); } catch { /* ignore */ }
      if (params.has("token")) {
        params.delete("token");
        const query = params.toString();
        history.replaceState(null, "", window.location.pathname + (query ? "?" + query : ""));
      }
      await loadProfiles();
    } catch (error) {
      setStatus("Connection failed", false);
      showToast(error.message, true);
    }
  }

  newBtn.addEventListener("click", createNew);
  refreshBtn.addEventListener("click", refresh);
  saveBtn.addEventListener("click", save);
  activateBtn.addEventListener("click", activate);
  deleteBtn.addEventListener("click", remove);
  nameInput.addEventListener("input", () => { setDirty(true); updateButtons(); });
  yamlInput.addEventListener("input", () => { setDirty(true); updateButtons(); });
  $("tokenBtn").addEventListener("click", () => {
    token = $("tokenInput").value.trim();
    if (!token) return;
    boot();
  });
  $("tokenInput").addEventListener("keydown", (event) => {
    if (event.key === "Enter") $("tokenBtn").click();
  });
  window.addEventListener("beforeunload", (event) => {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = "";
  });

  boot();
})();
