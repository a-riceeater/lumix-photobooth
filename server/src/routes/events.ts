import { Router, type Request } from "express";
import type { Ctx } from "../context.js";
import type { EventRow } from "../db.js";
import { HttpError, notFound } from "../errors.js";
import { isEventId } from "../ids.js";
import { readCookie } from "../middleware.js";

export type GalleryAccess = "ok" | "password_required" | "disabled";

export const galleryCookieName = (eventId: string) => `pb_gallery_${eventId.replace(/-/g, "_")}`;

/**
 * Event-wide galleries are off by default. "password" mode grants access via
 * a signed cookie bound to the current password hash, so changing the
 * password logs everyone out. Admins can always view.
 */
export function galleryAccess(ctx: Ctx, req: Request, event: EventRow | undefined): GalleryAccess {
  if (!event) return "disabled";
  if (ctx.cookies.verify(readCookie(req, "pb_admin")) === "admin") return "ok";
  if (event.gallery_mode === "public") return "ok";
  if (event.gallery_mode === "disabled") return "disabled";
  const token = ctx.cookies.verify(readCookie(req, galleryCookieName(event.id)));
  return token !== null && token === `${event.id}:${event.gallery_password_hash}` ? "ok" : "password_required";
}

export function eventGalleryRouter(ctx: Ctx): Router {
  const r = Router();
  const base = ctx.cfg.publicBaseUrl;

  const load = (req: Request) => {
    const id = req.params.eventId as string;
    const event = isEventId(id) ? ctx.sessions.getEvent(id) : undefined;
    const access = galleryAccess(ctx, req, event);
    if (access === "disabled") throw notFound("Gallery not found");
    if (access === "password_required") throw new HttpError(401, "password_required", "This gallery is password protected");
    return event!;
  };

  r.get("/:eventId", (req, res) => {
    const event = load(req);
    const total = (ctx.db.prepare(`SELECT COUNT(*) n FROM sessions WHERE event_id = ? AND status = 'complete'`).get(event.id) as { n: number }).n;
    res.json({ id: event.id, name: event.name, accentColor: event.accent_color, sessionCount: total });
  });

  r.get("/:eventId/sessions", (req, res) => {
    const event = load(req);
    const limit = Math.min(60, Math.max(1, Number(req.query.limit) || 24));
    const offset = Math.max(0, Number(req.query.offset) || 0);
    const rows = ctx.sessions.completedSessions(event.id, limit + 1, offset);
    res.json({
      sessions: rows.slice(0, limit).map((s) => ({
        id: s.id,
        url: ctx.sessions.galleryUrl(s.id),
        thumbUrl: `${base}/api/sessions/${s.id}/photos/0?size=thumb`,
        photoCount: s.photo_count,
        capturedAt: s.captured_at ?? s.created_at,
      })),
      nextOffset: rows.length > limit ? offset + limit : null,
    });
  });

  return r;
}
