// Session gallery: strip preview with design picker, photos, viewer, sharing.
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const sessionId = decodeURIComponent(location.pathname.split("/").filter(Boolean).pop() || "");
  const api = `/api/sessions/${encodeURIComponent(sessionId)}`;
  let data = null;
  let current = 0;
  let pollTimer = null;

  const show = (id) => {
    for (const s of ["processing", "error", "content"]) $(s).classList.toggle("hidden", s !== id);
  };

  async function load() {
    try {
      const res = await fetch(api, { cache: "no-store" });
      if (res.status === 202) {
        show("processing");
        clearTimeout(pollTimer);
        pollTimer = setTimeout(load, 5000);
        return;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      data = await res.json();
      render();
    } catch (e) {
      console.warn(e);
      show("error");
    }
  }

  function render() {
    show("content");
    $("event-name").textContent = data.event.name;
    if (data.event.galleryUrl) {
      $("event-gallery-link").href = data.event.galleryUrl;
      $("event-gallery-name").textContent = data.event.name;
      $("event-gallery-link").classList.remove("hidden");
    }
    document.title = `Your photos · ${data.event.name}`;
    if (data.event.accentColor) document.documentElement.style.setProperty("--accent", data.event.accentColor);

    const designs = data.designs;
    const fromUrl = new URLSearchParams(location.search).get("design");
    const initial = designs.find((d) => d.id === fromUrl) || designs.find((d) => d.id === data.defaultDesign) || designs[0];
    const picker = $("designs");
    picker.replaceChildren();
    $("design-section").classList.toggle("hidden", designs.length < 2);
    for (const d of designs) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "design";
      b.dataset.id = d.id;
      const img = document.createElement("img");
      img.src = d.thumbnailUrl;
      img.alt = "";
      img.loading = "lazy";
      const label = document.createElement("span");
      label.textContent = d.name;
      b.append(img, label);
      b.addEventListener("click", () => selectDesign(d));
      picker.append(b);
    }
    if (initial) selectDesign(initial, true);
    else document.querySelector(".strip-layout").classList.add("hidden");

    const grid = $("photos");
    grid.replaceChildren();
    data.photos.forEach((p, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("aria-label", `Open photo ${i + 1}`);
      const img = document.createElement("img");
      img.src = p.thumbUrl;
      img.alt = `Photo ${i + 1}`;
      img.loading = "lazy";
      img.width = 480;
      img.height = 320;
      b.append(img);
      b.addEventListener("click", () => openViewer(i));
      grid.append(b);
    });
    $("download-all").href = data.downloadAllUrl;
    if (navigator.share) {
      $("share-link").classList.remove("hidden");
      $("strip-share").classList.remove("hidden");
      $("viewer-share").classList.remove("hidden");
    }
  }

  function selectDesign(d, initial = false) {
    const img = $("strip");
    img.classList.add("loading");
    img.onload = () => img.classList.remove("loading");
    img.onerror = () => img.classList.remove("loading");
    img.src = d.previewUrl;
    img.alt = `Photo strip, ${d.name} design`;
    $("strip-download").href = d.downloadUrl;
    $("strip-download").dataset.url = d.downloadUrl.replace("&download=1", "");
    $("strip-download").dataset.name = `${d.id}.jpg`;
    for (const b of document.querySelectorAll(".design")) b.setAttribute("aria-pressed", String(b.dataset.id === d.id));
    if (!initial) {
      const u = new URL(location.href);
      u.searchParams.set("design", d.id);
      history.replaceState(null, "", u);
    }
  }

  // -- viewer ------------------------------------------------------------------
  const viewer = $("viewer");
  function openViewer(i) {
    current = (i + data.photos.length) % data.photos.length;
    const p = data.photos[current];
    $("viewer-img").src = p.mediumUrl;
    $("viewer-img").alt = `Photo ${current + 1} of ${data.photos.length}`;
    $("viewer-download").href = p.downloadUrl;
    if (!viewer.open) viewer.showModal();
  }
  $("viewer-prev").addEventListener("click", () => openViewer(current - 1));
  $("viewer-next").addEventListener("click", () => openViewer(current + 1));
  $("viewer-close").addEventListener("click", () => viewer.close());
  viewer.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") openViewer(current - 1);
    if (e.key === "ArrowRight") openViewer(current + 1);
  });
  let touchX = null;
  viewer.addEventListener("touchstart", (e) => { touchX = e.touches[0].clientX; }, { passive: true });
  viewer.addEventListener("touchend", (e) => {
    if (touchX === null) return;
    const dx = e.changedTouches[0].clientX - touchX;
    if (Math.abs(dx) > 50) openViewer(current + (dx < 0 ? 1 : -1));
    touchX = null;
  });

  // -- sharing -------------------------------------------------------------------
  async function shareFile(url, name) {
    try {
      const blob = await (await fetch(url)).blob();
      const file = new File([blob], name, { type: "image/jpeg" });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({ files: [file], title: data.event.name });
        return;
      }
    } catch (e) {
      if (e && e.name === "AbortError") return;
    }
    shareLink();
  }
  function shareLink() {
    navigator.share({ title: `Photos from ${data.event.name}`, url: location.href.split("?")[0] }).catch(() => {});
  }
  $("share-link").addEventListener("click", shareLink);
  $("strip-share").addEventListener("click", () => {
    const a = $("strip-download");
    shareFile(a.dataset.url, a.dataset.name);
  });
  $("viewer-share").addEventListener("click", () => {
    const p = data.photos[current];
    shareFile(p.originalUrl, `photo-${current + 1}.jpg`);
  });
  $("retry").addEventListener("click", load);

  load();
})();
