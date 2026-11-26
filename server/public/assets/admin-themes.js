// Admin: themes list and the single-column theme builder.
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const form = $("builder-form");
  let defaults = null;
  let themes = [];
  let editing = null;          // theme being edited, or null for a new one
  let bgData = null;           // data URL of a newly chosen background
  let fgData = null;
  let previewTimer = null;
  let previewSeq = 0;
  let previewUrl = null;

  async function api(method, path, body) {
    const res = await fetch(`/api/admin${path}`, {
      method,
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
    });
    if (!res.ok) {
      const j = await res.json().catch(() => ({}));
      throw new Error(j.message || `HTTP ${res.status}`);
    }
    return res;
  }

  // -- list ----------------------------------------------------------------------
  async function load() {
    let data;
    try {
      data = await (await api("GET", "/themes")).json();
    } catch {
      return; // not signed in yet; admin.js shows the login form
    }
    defaults = data.defaults;
    themes = data.themes;
    const font = $("b-font");
    if (!font.options.length) {
      for (const f of data.fonts) font.append(new Option(f.split(",")[0].replace(/'/g, ""), f));
    }
    render();
  }

  function render() {
    const grid = $("themes");
    grid.replaceChildren();
    for (const t of themes) {
      const card = document.createElement("div");
      card.className = "theme-card" + (t.enabled ? "" : " off");
      const img = document.createElement("img");
      img.src = t.previewUrl;
      img.alt = "";
      img.loading = "lazy";
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = t.name + (t.enabled ? "" : " (hidden)");
      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent = `${t.photoCount} photo${t.photoCount === 1 ? "" : "s"} · ${t.width}×${t.height}${t.editable ? " · made here" : ""}`;
      const btns = document.createElement("div");
      btns.className = "btns";
      if (t.editable) btns.append(button("Edit", () => openBuilder(t)));
      btns.append(button(t.enabled ? "Hide" : "Show", () => toggle(t)));
      btns.append(button("Delete", () => remove(t)));
      card.append(img, name, meta, btns);
      grid.append(card);
    }
  }

  function button(text, onClick) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "btn";
    b.textContent = text;
    b.addEventListener("click", onClick);
    return b;
  }

  async function toggle(t) {
    await api("PATCH", `/themes/${t.id}`, { enabled: !t.enabled });
    changed();
  }

  async function remove(t) {
    if (!confirm(`Delete the theme "${t.name}"?\nIt is moved to designs/_trash and can be restored from there.`)) return;
    await api("DELETE", `/themes/${t.id}`, {});
    changed();
  }

  function changed() {
    load();
    window.dispatchEvent(new Event("themes-changed"));
  }

  // -- builder ---------------------------------------------------------------------
  function openBuilder(theme) {
    editing = theme || null;
    const p = { ...defaults, ...(theme ? theme.builder : {}) };
    if (!theme) p.name = "";
    bgData = null;
    fgData = null;
    $("b-bg").value = "";
    $("b-fg").value = "";
    $("b-bg-remove").checked = false;
    $("b-fg-remove").checked = false;
    $("b-bg-remove").parentElement.classList.toggle("hidden", !(theme && theme.hasBackground));
    $("b-fg-remove").parentElement.classList.toggle("hidden", !(theme && theme.hasForeground));
    for (const el of form.elements) {
      if (!el.name || !(el.name in p)) continue;
      if (el.type === "checkbox") el.checked = Boolean(p[el.name]);
      else el.value = p[el.name];
    }
    syncPreset();
    $("builder-title").textContent = theme ? `Edit “${theme.name}”` : "New single-column theme";
    $("builder-error").textContent = "";
    $("builder").classList.remove("hidden");
    $("builder").scrollIntoView({ behavior: "smooth", block: "start" });
    schedulePreview(0);
  }

  function closeBuilder() {
    $("builder").classList.add("hidden");
    editing = null;
  }

  function params() {
    const p = { layout: "single-column" };
    for (const el of form.elements) {
      if (!el.name) continue;
      if (el.type === "checkbox") p[el.name] = el.checked;
      else if (el.type === "number") p[el.name] = el.value === "" ? undefined : Number(el.value);
      else p[el.name] = el.value;
    }
    if (!p.name) p.name = "Untitled theme";
    return p;
  }

  function payload() {
    return {
      id: editing ? editing.id : undefined,
      params: params(),
      background: bgData,
      foreground: fgData,
      removeBackground: $("b-bg-remove").checked,
      removeForeground: $("b-fg-remove").checked,
    };
  }

  function syncPreset() {
    const v = `${$("b-width").value}x${$("b-height").value}`;
    const sel = $("b-preset");
    sel.value = [...sel.options].some((o) => o.value === v) ? v : "custom";
  }

  function schedulePreview(delay = 500) {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(updatePreview, delay);
  }

  async function updatePreview() {
    const seq = ++previewSeq;
    $("preview-status").textContent = "Updating preview…";
    try {
      const blob = await (await api("POST", "/themes/preview", payload())).blob();
      if (seq !== previewSeq) return; // a newer preview is on its way
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      previewUrl = URL.createObjectURL(blob);
      $("builder-preview").src = previewUrl;
      $("preview-status").textContent = "Preview with sample photos";
      $("builder-error").textContent = "";
    } catch (e) {
      if (seq !== previewSeq) return;
      $("preview-status").textContent = "Preview not updated";
      $("builder-error").textContent = e.message;
    }
  }

  function readFile(input, done) {
    const file = input.files[0];
    if (!file) return done(null);
    if (file.size > 25 * 1024 * 1024) {
      $("builder-error").textContent = "Images must be smaller than 25 MB.";
      input.value = "";
      return done(null);
    }
    const r = new FileReader();
    r.onload = () => done(r.result);
    r.readAsDataURL(file);
  }

  $("new-theme").addEventListener("click", () => openBuilder(null));
  $("builder-cancel").addEventListener("click", closeBuilder);
  $("builder-close").addEventListener("click", closeBuilder);
  window.addEventListener("designs-reloaded", load);
  $("b-preset").addEventListener("change", () => {
    const v = $("b-preset").value;
    if (v === "custom") return;
    const [w, h] = v.split("x");
    $("b-width").value = w;
    $("b-height").value = h;
    schedulePreview(0);
  });
  $("b-bg").addEventListener("change", () => readFile($("b-bg"), (d) => { bgData = d; schedulePreview(0); }));
  $("b-fg").addEventListener("change", () => readFile($("b-fg"), (d) => { fgData = d; schedulePreview(0); }));
  form.addEventListener("input", (e) => {
    if (e.target.type === "file") return;
    if (e.target.id === "b-width" || e.target.id === "b-height") syncPreset();
    schedulePreview();
  });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const save = $("builder-save");
    save.disabled = true;
    save.textContent = "Saving…";
    try {
      await api("POST", "/themes", payload());
      closeBuilder();
      changed();
    } catch (err) {
      $("builder-error").textContent = err.message;
    } finally {
      save.disabled = false;
      save.textContent = "Save theme";
    }
  });

  load();
})();
