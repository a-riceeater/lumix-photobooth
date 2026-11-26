// Admin UI: thin client over /api/admin.
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const el = (tag, props = {}, ...children) => {
    const e = Object.assign(document.createElement(tag), props);
    e.append(...children);
    return e;
  };
  const mb = (b) => `${(b / 1048576).toFixed(1)} MB`;

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
    $("app").classList.add("hidden");
    if (new URLSearchParams(location.search).has("error")) $("login-error").classList.remove("hidden");
  }

  async function refresh() {
    let data;
    try {
      data = await call("GET", "/overview");
    } catch {
      return;
    }
    $("login").classList.add("hidden");
    $("app").classList.remove("hidden");
    $("summary").textContent = `Public URL: ${data.publicBaseUrl} · Email: ${data.emailEnabled ? "enabled" : "disabled (no SMTP)"} · ` +
      `Designs: ${data.designs.map((d) => `${d.id} (${d.photoCount})`).join(", ") || "none"}`;
    const probs = $("design-problems");
    probs.replaceChildren();
    for (const p of data.designProblems) {
      const kind = p.errors.length ? "bad" : "warn";
      probs.append(el("p", {}, el("span", { className: `pill ${kind}`, textContent: p.errors.length ? "invalid design" : "design warning" }),
        ` ${p.id}: ${[...p.errors, ...p.warnings].join("; ")}`));
    }
    const list = $("events");
    list.replaceChildren();
    if (!data.events.length) list.append(el("p", { className: "muted", textContent: "No events yet." }));
    for (const ev of data.events) list.append(renderEvent(ev, data.designs));
  }

  function renderEvent(ev, designs) {
    const node = $("event-tpl").content.firstElementChild.cloneNode(true);
    const q = (s) => node.querySelector(s);
    q(".ev-title").textContent = `${ev.name} (${ev.id})`;
    q(".ev-stats").textContent = `${ev.complete} complete, ${ev.uploading} uploading · ${ev.photos} photos (${mb(ev.bytes)}) · ` +
      `emails: ${ev.emails.sent} sent, ${ev.emails.pending} pending, ${ev.emails.failed} failed`;
    const form = q(".ev-form");
    form.name.value = ev.name;
    form.galleryMode.value = ev.galleryMode;
    form.accentColor.value = ev.accentColor || "";
    form.galleryPassword.placeholder = ev.galleryPasswordSet ? "unchanged" : "not set";
    form.defaultDesign.append(el("option", { value: "", textContent: "(automatic)" }));
    for (const d of designs) form.defaultDesign.append(el("option", { value: d.id, textContent: `${d.name} (${d.photoCount} photos)` }));
    form.defaultDesign.value = ev.defaultDesign || "";
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const patch = {
        name: form.name.value,
        galleryMode: form.galleryMode.value,
        accentColor: form.accentColor.value || null,
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
    q(".ev-gallery").href = ev.galleryUrl;
    q(".ev-sessions").addEventListener("click", () => loadSessions(ev, q(".ev-table")));
    q(".ev-delete").addEventListener("click", async () => {
      const typed = prompt(`This permanently deletes ${ev.sessions} sessions and all their photos.\nType the event id (${ev.id}) to confirm:`);
      if (typed !== ev.id) return;
      await call("DELETE", `/events/${ev.id}`, { confirm: ev.id });
      refresh();
    });
    return node;
  }

  async function loadSessions(ev, container) {
    const { sessions } = await call("GET", `/events/${ev.id}/sessions?limit=200`);
    const rows = sessions.map((s) => {
      const status = s.status === "complete" ? el("span", { className: "pill ok", textContent: "complete" })
        : el("span", { className: "pill warn", textContent: `uploading ${s.uploaded}/${s.photoCount}` });
      const emails = s.emails.map((m) => `${m.masked} ${m.status}${m.last_error ? ` (${m.last_error})` : ""}`).join(", ");
      const del = el("button", { className: "btn", type: "button", textContent: "Delete" });
      del.addEventListener("click", async () => {
        if (!confirm("Delete this session and its photos permanently?")) return;
        await call("DELETE", `/sessions/${s.id}`);
        loadSessions(ev, container);
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
      : el("p", { className: "muted", textContent: "No sessions." }));
  }

  $("new-event").addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await call("POST", "/events", { id: $("ne-id").value.trim(), name: $("ne-name").value.trim() });
      e.target.reset();
      refresh();
    } catch (err) {
      alert(err.message);
    }
  });
  $("reload-designs").addEventListener("click", async () => {
    const r = await call("POST", "/designs/reload", {});
    alert(`${r.loaded} designs loaded.`);
    refresh();
  });
  $("retry-emails").addEventListener("click", async () => {
    const r = await call("POST", "/emails/retry", {});
    alert(`${r.requeued} emails queued again.`);
    refresh();
  });
  window.addEventListener("themes-changed", refresh);
  refresh();
})();
