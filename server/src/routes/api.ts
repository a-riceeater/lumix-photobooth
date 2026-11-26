import express, { Router, type Request, type Response } from "express";
import archiver from "archiver";
import fs from "node:fs";
import { defaultDesignFor, downloadName, viewableSession, type Ctx } from "../context.js";
import { designSummary } from "../designs.js";
import { badRequest, notFound } from "../errors.js";
import { isDesignId, safeEqual, SESSION_ID_RE } from "../ids.js";
import type { PhotoSize } from "../images.js";
import { log } from "../log.js";
import { rateLimit, requireDevice } from "../middleware.js";
import { Storage } from "../storage.js";
import { eventGalleryRouter } from "./events.js";

const IMMUTABLE = "public, max-age=31536000, immutable";

export function apiRouter(ctx: Ctx): Router {
  const r = Router();
  const device = requireDevice(ctx.cfg.deviceApiKey);
  const json = express.json({ limit: "64kb" });
  const jpegBody = express.raw({ type: ["image/jpeg", "image/jpg", "application/octet-stream"], limit: ctx.cfg.maxUploadBytes });
  const base = ctx.cfg.publicBaseUrl;

  r.use((_req, res, next) => {
    res.setHeader("Cache-Control", "no-store");
    next();
  });

  // -- discovery -------------------------------------------------------------

  r.get("/health", (_req, res) => {
    ctx.db.prepare("SELECT 1").get();
    res.json({ ok: true, time: new Date().toISOString(), emailEnabled: ctx.email.enabled, designs: ctx.designs.list().length });
  });

  r.get("/config", (req, res) => {
    const header = req.get("authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    res.json({
      publicBaseUrl: base,
      galleryUrlTemplate: `${base}/s/{sessionId}`,
      sessionIdPattern: SESSION_ID_RE.source,
      emailEnabled: ctx.email.enabled,
      maxUploadBytes: ctx.cfg.maxUploadBytes,
      authenticated: token !== "" && safeEqual(token, ctx.cfg.deviceApiKey),
    });
  });

  r.get("/designs", (req, res) => {
    const count = req.query.photoCount === undefined ? undefined : Number(req.query.photoCount);
    if (count !== undefined && !Number.isInteger(count)) throw badRequest("photoCount must be an integer");
    const list = count === undefined ? ctx.designs.list() : ctx.designs.compatible(count);
    res.json({ designs: list.map((d) => ({ ...designSummary(d), previewUrl: `${base}/api/designs/${d.id}/preview` })) });
  });

  r.get("/designs/:id/preview", async (req, res) => {
    const d = ctx.designs.get(req.params.id);
    if (!d) throw notFound("Design not found");
    res.setHeader("Cache-Control", "public, max-age=300");
    if (d.preview) return res.sendFile(`${d.dir}/${d.preview}`);
    res.type("jpeg").send(await ctx.images.placeholderPreview(d));
  });

  // -- device (authenticated) ------------------------------------------------

  r.post("/sessions", device, json, (req, res) => {
    const { session, created } = ctx.sessions.createSession(req.body ?? {});
    res.status(created ? 201 : 200).json({ ...ctx.sessions.status(session.id), created });
  });

  r.post("/sessions/:id/photos", device, jpegBody, async (req, res) => {
    const index = req.query.index ?? req.get("x-photo-index");
    const sha = req.query.sha256 ?? req.get("x-photo-sha256");
    const result = await ctx.sessions.addPhoto(req.params.id, index, req.body, sha);
    res.status(result.duplicate ? 200 : 201).json(result);
  });

  r.post("/sessions/:id/complete", device, json, (req, res) => {
    ctx.sessions.complete(req.params.id, req.body?.sha256);
    void ctx.email.processDue();
    res.json(ctx.sessions.status(req.params.id));
  });

  r.get("/sessions/:id/status", device, (req, res) => {
    res.json(ctx.sessions.status(req.params.id));
  });

  r.post("/sessions/:id/email", device, rateLimit({ windowMs: 60_000, max: 30, scope: "email" }), json, (req, res) => {
    const result = ctx.email.enqueue(req.params.id, req.body?.email);
    res.status(result.duplicate ? 200 : 202).json(result);
  });

  // -- public session viewing ------------------------------------------------

  r.get("/sessions/:id", (req, res) => {
    const s = ctx.sessions.getSession(req.params.id);
    if (!s || s.status !== "complete") {
      // Unknown and in-progress sessions are indistinguishable on purpose.
      return res.status(202).json({ id: req.params.id, status: "processing" });
    }
    const { session, event } = viewableSession(ctx, req.params.id);
    const sid = session.id;
    const api = `${base}/api/sessions/${sid}`;
    const def = defaultDesignFor(ctx, session, event);
    res.json({
      id: sid,
      status: "complete",
      url: ctx.sessions.galleryUrl(sid),
      event: { id: event.id, name: event.name, accentColor: event.accent_color, galleryEnabled: event.gallery_mode !== "disabled" },
      capturedAt: session.captured_at ?? session.created_at,
      photos: ctx.sessions.photos(sid).map((p) => ({
        index: p.idx,
        width: p.width,
        height: p.height,
        thumbUrl: `${api}/photos/${p.idx}?size=thumb`,
        mediumUrl: `${api}/photos/${p.idx}?size=medium`,
        originalUrl: `${api}/photos/${p.idx}`,
        downloadUrl: `${api}/photos/${p.idx}?download=1`,
      })),
      designs: ctx.designs.compatible(session.photo_count).map((d) => ({
        ...designSummary(d),
        thumbnailUrl: `${base}/api/designs/${d.id}/preview`,
        previewUrl: `${api}/strip?design=${d.id}&size=preview`,
        downloadUrl: `${api}/strip?design=${d.id}&download=1`,
      })),
      defaultDesign: def?.id ?? null,
      downloadAllUrl: `${api}/download`,
    });
  });

  r.get("/sessions/:id/photos/:photoId", async (req, res) => {
    const { session, event } = viewableSession(ctx, req.params.id);
    const index = Number(req.params.photoId);
    if (!/^\d{1,2}$/.test(req.params.photoId) || !ctx.sessions.photo(session.id, index)) throw notFound("Photo not found");
    const size = (req.query.size ?? "original") as PhotoSize;
    if (!["thumb", "medium", "original"].includes(size)) throw badRequest("size must be thumb, medium or original");
    const file = await ctx.images.photoPath(session, index, size);
    res.setHeader("Cache-Control", IMMUTABLE);
    if (req.query.download) res.attachment(downloadName(event.id, session.id, Storage.originalName(index)));
    res.type("jpeg").sendFile(file);
  });

  r.get("/sessions/:id/strip", async (req, res) => {
    const { session, event } = viewableSession(ctx, req.params.id);
    const designId = req.query.design ?? defaultDesignFor(ctx, session, event)?.id;
    if (!isDesignId(designId)) throw notFound("Design not found");
    const design = ctx.designs.get(designId);
    if (!design || design.photoCount !== session.photo_count) throw notFound("Design not available for this session");
    const full = req.query.size !== "preview";
    const file = await ctx.images.stripPath(session, design, full, event.name);
    res.setHeader("Cache-Control", "public, max-age=3600");
    if (req.query.download) res.attachment(downloadName(event.id, session.id, `${design.id}.jpg`));
    res.type("jpeg").sendFile(file);
  });

  r.get("/sessions/:id/download", (req: Request, res: Response) => {
    const { session, event } = viewableSession(ctx, req.params.id as string);
    const photos = ctx.sessions.photos(session.id);
    res.setHeader("Cache-Control", "no-store");
    res.attachment(downloadName(event.id, session.id, "photos.zip"));
    // JPEGs do not compress; "store" keeps this fast and streaming.
    const zip = archiver("zip", { store: true });
    zip.on("warning", (e) => log.warn("zip warning", { error: e.message }));
    zip.on("error", (e) => {
      log.error("zip failed", { error: e.message });
      res.destroy(e);
    });
    zip.pipe(res);
    for (const p of photos) {
      const file = ctx.images.originalPath(session, p.idx);
      zip.append(fs.createReadStream(file), { name: downloadName(event.id, session.id, p.filename) });
    }
    void zip.finalize();
  });

  r.use("/events", eventGalleryRouter(ctx));
  return r;
}
