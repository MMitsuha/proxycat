(() => {
  const params = new URLSearchParams(window.location.search);
  const storedToken = (() => {
    try { return sessionStorage.getItem("proxycat-web-token") || ""; } catch { return ""; }
  })();
  let token = params.get("token") || storedToken || "";
  let profiles = [];
  let current = null; // {id, name, yaml}
  let dirty = false;

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
      item.addEventListener("click", () => loadProfile(profile.id));

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
    profiles = await api("/api/profiles");
    renderProfiles();
    setStatus(
      profiles.length ? profiles.length + " profile" + (profiles.length === 1 ? "" : "s") : "No profiles",
      true
    );
    const wanted = selectId || (current && current.id) || (profiles.find((p) => p.isActive) || profiles[0] || {}).id;
    if (wanted) {
      const exists = profiles.some((p) => p.id === wanted);
      if (exists) await loadProfile(wanted);
    } else {
      current = null;
      editorPane.hidden = true;
      emptyState.hidden = false;
    }
  }

  async function loadProfile(id) {
    if (dirty && !confirm("Discard unsaved changes?")) return;
    const detail = await api("/api/profiles/" + encodeURIComponent(id));
    current = detail;
    nameInput.value = detail.name;
    yamlInput.value = detail.yaml;
    setDirty(false);
    updateButtons();
    renderProfiles();
    showEditor();
    setStatus("Editing " + detail.name, true);
  }

  function updateButtons() {
    activateBtn.disabled = !current;
    deleteBtn.disabled = !current;
    saveBtn.disabled = !nameInput.value.trim() || !yamlInput.value.trim();
  }

  async function save() {
    const name = nameInput.value.trim();
    const yaml = yamlInput.value;
    if (!name) { showToast("Profile name cannot be empty", true); return; }
    if (!yaml.trim()) { showToast("YAML cannot be empty", true); return; }
    saveBtn.disabled = true;
    try {
      if (current && current.id) {
        current = await api("/api/profiles/" + encodeURIComponent(current.id), {
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
      setDirty(false);
      showToast("Saved");
      await loadProfiles(current.id);
    } catch (error) {
      showToast(error.message, true);
    } finally {
      saveBtn.disabled = false;
      updateButtons();
    }
  }

  async function activate() {
    if (!current) return;
    try {
      await api("/api/profiles/" + encodeURIComponent(current.id) + "/activate", { method: "POST" });
      showToast("Activated");
      await loadProfiles(current.id);
    } catch (error) {
      showToast(error.message, true);
    }
  }

  async function remove() {
    if (!current) return;
    if (!confirm("Delete profile \"" + current.name + "\"?")) return;
    try {
      await api("/api/profiles/" + encodeURIComponent(current.id), { method: "DELETE" });
      current = null;
      setDirty(false);
      showToast("Deleted");
      await loadProfiles();
    } catch (error) {
      showToast(error.message, true);
    }
  }

  async function createNew() {
    if (dirty && !confirm("Discard unsaved changes?")) return;
    try {
      const template = await api("/api/default-profile");
      current = null;
      nameInput.value = "New Profile";
      yamlInput.value = template.yaml;
      setDirty(true);
      updateButtons();
      editorPane.hidden = false;
      emptyState.hidden = true;
      authPane.hidden = true;
      activateBtn.disabled = true;
      deleteBtn.disabled = true;
      setStatus("New profile", true);
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

  $("newBtn").addEventListener("click", createNew);
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
