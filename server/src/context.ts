import type { AppConfig } from "./config.js";
import type { DB, EventRow, SessionRow } from "./db.js";
import type { DesignRegistry } from "./designs.js";
import type { EmailService } from "./email.js";
import { notFound } from "./errors.js";
import type { ImageService } from "./images.js";
import type { CookieSigner } from "./middleware.js";
import type { SessionService } from "./sessions.js";
import type { Storage } from "./storage.js";

/** Everything route handlers need, created once in createApp(). */
export interface Ctx {
  cfg: AppConfig;
  db: DB;
  storage: Storage;
  sessions: SessionService;
  images: ImageService;
  designs: DesignRegistry;
  email: EmailService;
  cookies: CookieSigner;
}

/**
 * A session that guests may see: it exists and has finished uploading.
 * Unknown and still-uploading sessions look identical from outside.
 */
export function viewableSession(ctx: Ctx, id: string): { session: SessionRow; event: EventRow } {
  const session = ctx.sessions.getSession(id);
  if (!session || session.status !== "complete") throw notFound("Session not available");
  return { session, event: ctx.sessions.getEvent(session.event_id)! };
}

/** "summer-party-AbC123-01.jpg" style download names (ASCII only). */
export function downloadName(eventId: string, sessionId: string, suffix: string): string {
  return `${eventId}-${sessionId.slice(0, 6)}-${suffix}`.replace(/[^A-Za-z0-9._-]/g, "_");
}

/** Default design for a session: session choice, event default, then first compatible. */
export function defaultDesignFor(ctx: Ctx, session: SessionRow, event: EventRow) {
  const compatible = ctx.designs.compatible(session.photo_count);
  return compatible.find((d) => d.id === session.design_id)
    ?? compatible.find((d) => d.id === event.default_design)
    ?? compatible[0];
}
