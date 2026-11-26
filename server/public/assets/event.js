// Event-wide gallery: incremental loading of completed sessions.
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const eventId = decodeURIComponent(location.pathname.split("/").filter(Boolean).pop() || "");
  const api = `/api/events/${encodeURIComponent(eventId)}`;
  let next = 0;
  let busy = false;
  const loaded = [];   // sessions shown so far (re-rendered when the view changes)
  let view = "strips";
  try { view = localStorage.getItem("pb-gallery-view") === "photos" ? "photos" : "strips"; } catch {}

  function tile(s) {
    const a = document.createElement("a");
    a.className = "tile";
    a.href = s.url;
    const img = document.createElement("img");
    const strip = view === "strips" && s.stripUrl;
    img.src = strip ? s.stripUrl : s.thumbUrl;
    img.alt = `Session from ${new Date(s.capturedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`;
    img.loading = "lazy";
    img.decoding = "async";
    if (!strip) { img.width = 480; img.height = 320; }
    a.append(img);
    return a;
  }

  function setView(v) {
    view = v;
    try { localStorage.setItem("pb-gallery-view", v); } catch {}
    $("sessions").dataset.view = v;
    for (const b of document.querySelectorAll(".segmented button")) b.setAttribute("aria-pressed", String(b.dataset.view === v));
    $("sessions").replaceChildren(...loaded.map(tile));
  }
  for (const b of document.querySelectorAll(".segmented button")) b.addEventListener("click", () => setView(b.dataset.view));

  async function loadEvent() {
    const res = await fetch(api, { cache: "no-store" });
    if (!res.ok) return;
    const ev = await res.json();
    $("event-name").textContent = ev.name;
    document.title = ev.name;
    $("count").textContent = `${ev.sessionCount} photo booth session${ev.sessionCount === 1 ? "" : "s"}`;
    if (ev.accentColor) document.documentElement.style.setProperty("--accent", ev.accentColor);
    $("empty").classList.toggle("hidden", ev.sessionCount > 0);
  }

  async function loadMore() {
    if (busy || next === null) return;
    busy = true;
    try {
      const res = await fetch(`${api}/sessions?offset=${next}&limit=24`, { cache: "no-store" });
      if (!res.ok) return;
      const page = await res.json();
      for (const s of page.sessions) {
        loaded.push(s);
        $("sessions").append(tile(s));
      }
      next = page.nextOffset;
      $("more").classList.toggle("hidden", next === null);
    } finally {
      busy = false;
    }
  }

  $("more").addEventListener("click", loadMore);
  // Load further pages automatically as the visitor scrolls.
  if ("IntersectionObserver" in window) {
    new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) loadMore();
    }, { rootMargin: "600px" }).observe($("more"));
  }
  setView(view);
  loadEvent();
  loadMore();
})();
