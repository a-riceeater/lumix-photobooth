// Admin UI: thin client over /api/admin (events, system). Themes live in admin-themes.js.
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const el = (tag, props = {}, ...children) => {
    const e = Object.assign(document.createElement(tag), props);
    e.append(...children);
    return e;
  };
  const mb = (b) => (b >= 1073741824 ? `${(b / 1073741824).toFixed(1)} GB` : `${(b / 1048576).toFixed(0)} MB`);
  const openPanels = new Set();   // event ids whose settings/sessions are expanded

  async function call(method, path, body) {
    const res = await fetch(`/api/admin${path}`, {
      method,
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
    });
    const json = await res.json().catch(() => ({}));
    if (res.status === 401) {
      showLogin();
      throw new Error("Not signed in");
    }
    if (!res.ok) throw new Error(json.message || `HTTP ${res.status}`);
    return json;
  }

  function showLogin() {
    $("login").classList.remove("hidden");
    for (const id of ["app", "tabs", "signout"]) $(id).classList.add("hidden");
    if (new URLSearchParams(location.search).has("error")) $("login-error").classList.remove("hidden");
  }

  // -- tabs ------------------------------------------------------------------------
  function selectTab(name) {
    for (const b of document.querySelectorAll("#tabs button")) b.setAttribute("aria-selected", String(b.dataset.tab === name));
    for (const p of document.querySelectorAll("[data-panel]")) p.classList.toggle("hidden", p.dataset.panel !== name);
    try { localStorage.setItem("pb-admin-tab", name); } catch {}
    if (location.hash !== `#${name}`) history.replaceState(null, "", `#${name}`);
  }
  for (const b of document.querySelectorAll("#tabs button")) b.addEventListener("click", () => selectTab(b.dataset.tab));

  // -- data ------------------------------------------------------------------------
  async function refresh() {
    let data;
    try {
      data = await call("GET", "/overview");
    } catch {
      return;
    }
    $("login").classList.add("hidden");
    for (const id of ["app", "tabs", "signout"]) $(id).classList.remove("hidden");
    renderSystem(data);
    const list = $("events");
    list.replaceChildren();
    if (!data.events.length) list.append(el("p", { className: "muted", textContent: "No events yet." }));
    for (const ev of data.events) list.append(renderEvent(ev, data.designs));
  }

  function chip(text, kind = "") {
    return el("span", { className: `chip ${kind}`.trim(), textContent: text });
  }

  function renderEvent(ev, designs) {
    const node = $("event-tpl").content.firstElementChild.cloneNode(true);
    const q = (s) => node.querySelector(s);
    q(".ev-name").textContent = ev.name;
    q(".ev-id").textContent = ev.id;

    const galleryLabel = { disabled: "Gallery off", public: "Gallery public", password: "Gallery password" }[ev.galleryMode];
    q(".ev-chips").append(
      chip(`${ev.complete} session${ev.complete === 1 ? "" : "s"}`),
      chip(`${ev.photos} photos · ${mb(ev.bytes)}`),
      chip(galleryLabel, ev.galleryMode === "disabled" ? "" : "on"),
    );
    if (ev.uploading) q(".ev-chips").append(chip(`${ev.uploading} uploading`, "warn"));
    if (ev.emails.sent) q(".ev-chips").append(chip(`${ev.emails.sent} emailed`));
    if (ev.emails.pending) q(".ev-chips").append(chip(`${ev.emails.pending} email pending`, "warn"));
    if (ev.emails.failed) q(".ev-chips").append(chip(`${ev.emails.failed} email failed`, "bad"));

    const gallery = q(".ev-gallery");
    gallery.href = ev.galleryUrl;
    if (ev.galleryMode === "disabled") {
      gallery.setAttribute("aria-disabled", "true");
      gallery.title = "Turn the event gallery on in Settings";
    }

    // settings (one line)
    const form = q(".event-settings");
    form.name.value = ev.name;
    form.galleryMode.value = ev.galleryMode;
    form.galleryPassword.placeholder = ev.galleryPasswordSet ? "unchanged" : "not set";
    form.accentColor.value = ev.accentColor || "#18181b";
    form.useAccent.checked = Boolean(ev.accentColor);
    form.accentColor.addEventListener("input", () => { form.useAccent.checked = true; });
    form.defaultDesign.append(el("option", { value: "", textContent: "Automatic" }));
    for (const d of designs) form.defaultDesign.append(el("option", { value: d.id, textContent: `${d.name} (${d.photoCount})` }));
    form.defaultDesign.value = ev.defaultDesign || "";
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const patch = {
        name: form.name.value,
        galleryMode: form.galleryMode.value,
        accentColor: form.useAccent.checked ? form.accentColor.value : null,
        defaultDesign: form.defaultDesign.value || null,
      };
      if (form.galleryPassword.value) patch.galleryPassword = form.galleryPassword.value;
      try {
        await call("PATCH", `/events/${ev.id}`, patch);
        refresh();
      } catch (err) {
        q(".ev-msg").textContent = err.message;
      }
    });

    const toggle = (button, panel, key, onOpen) => {
      const open = (v) => {
        panel.classList.toggle("hidden", !v);
        button.setAttribute("aria-expanded", String(v));
        if (v) openPanels.add(key); else openPanels.delete(key);
        if (v && onOpen) onOpen();
      };
      button.addEventListener("click", () => open(panel.classList.contains("hidden")));
      if (openPanels.has(key)) open(true);
    };
    toggle(q(".ev-settings"), form, `${ev.id}:settings`);
    toggle(q(".ev-sessions"), q(".event-sessions"), `${ev.id}:sessions`, () => loadSessions(ev, q(".event-sessions")));

    q(".ev-delete").addEventListener("click", async () => {
      const typed = prompt(`This permanently deletes ${ev.sessions} sessions and all their photos.\nType the event id (${ev.id}) to confirm:`);
      if (typed !== ev.id) return;
      await call("DELETE", `/events/${ev.id}`, { confirm: ev.id });
      refresh();
    });
    return node;
  }

  async function loadSessions(ev, container) {
    container.replaceChildren(el("p", { className: "muted", textContent: "Loading…" }));
    const { sessions } = await call("GET", `/events/${ev.id}/sessions?limit=200`);
    const rows = sessions.map((s) => {
      const status = s.status === "complete" ? chip("complete", "on") : chip(`uploading ${s.uploaded}/${s.photoCount}`, "warn");
      const emails = s.emails.map((m) => `${m.masked} ${m.status}${m.last_error ? ` (${m.last_error})` : ""}`).join(", ");
      const del = el("button", { className: "btn small danger", type: "button", textContent: "Delete" });
      del.addEventListener("click", async () => {
        if (!confirm("Delete this session and its photos permanently?")) return;
        await call("DELETE", `/sessions/${s.id}`);
        refresh();
      });
      return el("tr", {},
        el("td", {}, el("a", { href: s.url, target: "_blank", rel: "noopener", textContent: s.id.slice(0, 8) + "…" })),
        el("td", {}, status),
        el("td", { textContent: new Date(s.capturedAt || s.createdAt).toLocaleString() }),
        el("td", { textContent: s.deviceName || "" }),
        el("td", { textContent: emails }),
        el("td", {}, del));
    });
    const head = el("tr", {}, ...["Session", "Status", "Captured", "Device", "Emails", ""].map((h) => el("th", { textContent: h })));
    container.replaceChildren(sessions.length ? el("table", {}, el("thead", {}, head), el("tbody", {}, ...rows))
      : el("p", { className: "muted", textContent: "No sessions yet." }));
  }

  function renderSystem(data) {
    const facts = $("facts");
    facts.replaceChildren();
    const add = (k, v) => facts.append(el("dt", { textContent: k }), el("dd", { textContent: v }));
    add("Public URL", data.publicBaseUrl);
    add("Email", data.emailEnabled ? "Enabled" : "Disabled (SMTP not configured)");
    add("Events", String(data.events.length));
    add("Themes", `${data.designs.length} installed`);
    const probs = $("design-problems");
    probs.replaceChildren();
    if (!data.designProblems.length) probs.append(el("p", { className: "muted", textContent: "None." }));
    for (const p of data.designProblems) {
      probs.append(el("p", {}, chip(p.errors.length ? "invalid" : "warning", p.errors.length ? "bad" : "warn"),
        ` ${p.id}: ${[...p.errors, ...p.warnings].join("; ")}`));
    }
  }

  // -- actions -----------------------------------------------------------------------
  $("ne-name").addEventListener("input", () => {
    const slug = $("ne-name").value.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
    if (!$("ne-id").dataset.touched) $("ne-id").value = slug;
  });
  $("ne-id").addEventListener("input", () => { $("ne-id").dataset.touched = "1"; });
  $("new-event").addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await call("POST", "/events", { id: $("ne-id").value.trim(), name: $("ne-name").value.trim() });
      e.target.reset();
      delete $("ne-id").dataset.touched;
      refresh();
    } catch (err) {
      alert(err.message);
    }
  });
  $("reload-designs").addEventListener("click", async () => {
    const r = await call("POST", "/designs/reload", {});
    alert(`${r.loaded} designs loaded.`);
    refresh();
    window.dispatchEvent(new Event("designs-reloaded"));
  });
  $("retry-emails").addEventListener("click", async () => {
    const r = await call("POST", "/emails/retry", {});
    alert(`${r.requeued} emails queued again.`);
    refresh();
  });

  window.addEventListener("themes-changed", refresh);
  let initial = location.hash.slice(1);
  if (!initial) { try { initial = localStorage.getItem("pb-admin-tab") || ""; } catch {} }
  selectTab(["events", "themes", "system"].includes(initial) ? initial : "events");
  refresh();
})();
