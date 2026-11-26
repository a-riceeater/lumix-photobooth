import type { Ctx } from "./context.js";
import { type EventRow, type GalleryMode, type SessionRow } from "./db.js";
import { badRequest, notFound } from "./errors.js";
import { isDesignId, isEventId } from "./ids.js";
import { log } from "./log.js";
import { hashPassword } from "./middleware.js";

/** Administrative operations shared by the /admin UI and the CLI. */
export class AdminOps {
  constructor(private readonly ctx: Ctx) {}

  private get db() {
    return this.ctx.db;
  }

  overview() {
    const events = this.db.prepare(`SELECT * FROM events ORDER BY created_at DESC`).all() as EventRow[];
    const stat = this.db.prepare(
      `SELECT COUNT(*) total, SUM(status = 'complete') complete, SUM(status = 'uploading') uploading FROM sessions WHERE event_id = ?`,
    );
    const photos = this.db.prepare(`SELECT COUNT(*) n, COALESCE(SUM(bytes), 0) bytes FROM photos p JOIN sessions s ON s.id = p.session_id WHERE s.event_id = ?`);
    const emails = this.db.prepare(
      `SELECT SUM(e.status IN ('pending','sending')) pending, SUM(e.status = 'failed') failed, SUM(e.status = 'sent') sent
       FROM emails e JOIN sessions s ON s.id = e.session_id WHERE s.event_id = ?`,
    );
    return {
      emailEnabled: this.ctx.email.enabled,
      publicBaseUrl: this.ctx.cfg.publicBaseUrl,
      designs: this.ctx.designs.list().map((d) => ({ id: d.id, name: d.name, photoCount: d.photoCount, width: d.width, height: d.height })),
      designProblems: this.ctx.designs.getProblems(),
      events: events.map((e) => {
        const s = stat.get(e.id) as { total: number; complete: number | null; uploading: number | null };
        const p = photos.get(e.id) as { n: number; bytes: number };
        const m = emails.get(e.id) as { pending: number | null; failed: number | null; sent: number | null };
        return {
          ...this.publicEvent(e),
          galleryUrl: `${this.ctx.cfg.publicBaseUrl}/gallery/${e.id}`,
          sessions: s.total,
          complete: s.complete ?? 0,
          uploading: s.uploading ?? 0,
          photos: p.n,
          bytes: p.bytes,
          emails: { pending: m.pending ?? 0, failed: m.failed ?? 0, sent: m.sent ?? 0 },
        };
      }),
    };
  }

  publicEvent(e: EventRow) {
    return {
      id: e.id,
      name: e.name,
      createdAt: e.created_at,
      galleryMode: e.gallery_mode,
      galleryPasswordSet: Boolean(e.gallery_password_hash),
      accentColor: e.accent_color,
      defaultDesign: e.default_design,
    };
  }

  createEvent(id: unknown, name: unknown): EventRow {
    if (!isEventId(id)) throw badRequest("Event id must be a lowercase slug (letters, digits, dashes)");
    if (this.ctx.sessions.getEvent(id)) throw badRequest("Event already exists");
    const n = typeof name === "string" && name.trim() ? name.trim().slice(0, 120) : id;
    return this.ctx.sessions.ensureEvent(id, n);
  }

  updateEvent(id: string, patch: Record<string, unknown>): EventRow {
    const e = this.ctx.sessions.getEvent(id);
    if (!e) throw notFound("Event not found");
    const next = { ...e };
    if (patch.name !== undefined) {
      if (typeof patch.name !== "string" || !patch.name.trim()) throw badRequest("name must be a non-empty string");
      next.name = patch.name.trim().slice(0, 120);
    }
    if (patch.galleryMode !== undefined) {
      if (!["disabled", "public", "password"].includes(patch.galleryMode as string)) throw badRequest("galleryMode must be disabled, public or password");
      next.gallery_mode = patch.galleryMode as GalleryMode;
    }
    if (patch.galleryPassword !== undefined) {
      if (patch.galleryPassword === null || patch.galleryPassword === "") next.gallery_password_hash = null;
      else if (typeof patch.galleryPassword !== "string" || patch.galleryPassword.length < 4) throw badRequest("galleryPassword must be at least 4 characters");
      else next.gallery_password_hash = hashPassword(patch.galleryPassword);
    }
    if (patch.accentColor !== undefined) {
      if (patch.accentColor !== null && (typeof patch.accentColor !== "string" || !/^#[0-9a-fA-F]{6}$/.test(patch.accentColor))) {
        throw badRequest("accentColor must look like #336699");
      }
      next.accent_color = (patch.accentColor as string | null) || null;
    }
    if (patch.defaultDesign !== undefined) {
      if (patch.defaultDesign !== null && (!isDesignId(patch.defaultDesign) || !this.ctx.designs.get(patch.defaultDesign))) {
        throw badRequest("defaultDesign must be an installed design id");
      }
      next.default_design = (patch.defaultDesign as string | null) || null;
    }
    if (next.gallery_mode === "password" && !next.gallery_password_hash) throw badRequest("Set a gallery password before enabling password mode");
    this.db.prepare(
      `UPDATE events SET name = @name, gallery_mode = @gallery_mode, gallery_password_hash = @gallery_password_hash,
       accent_color = @accent_color, default_design = @default_design WHERE id = @id`,
    ).run(next);
    log.info("event updated", { event: id, galleryMode: next.gallery_mode });
    return next;
  }

  async deleteEvent(id: string): Promise<void> {
    if (!this.ctx.sessions.getEvent(id)) throw notFound("Event not found");
    this.db.prepare(`DELETE FROM events WHERE id = ?`).run(id);
    await this.ctx.storage.removeEvent(id);
    log.info("event deleted", { event: id });
  }

  sessions(eventId: string, opts: { status?: string; limit?: number; offset?: number } = {}) {
    const limit = Math.min(200, Math.max(1, opts.limit ?? 50));
    const offset = Math.max(0, opts.offset ?? 0);
    const where = opts.status === "complete" || opts.status === "uploading" ? `AND status = '${opts.status}'` : "";
    const rows = this.db.prepare(
      `SELECT * FROM sessions WHERE event_id = ? ${where} ORDER BY created_at DESC LIMIT ? OFFSET ?`,
    ).all(eventId, limit, offset) as SessionRow[];
    const photoCount = this.db.prepare(`SELECT COUNT(*) n FROM photos WHERE session_id = ?`);
    const emails = this.db.prepare(`SELECT masked, status, attempts, last_error, sent_at FROM emails WHERE session_id = ? ORDER BY id`);
    return rows.map((s) => ({
      id: s.id,
      url: this.ctx.sessions.galleryUrl(s.id),
      status: s.status,
      photoCount: s.photo_count,
      uploaded: (photoCount.get(s.id) as { n: number }).n,
      createdAt: s.created_at,
      capturedAt: s.captured_at,
      completedAt: s.completed_at,
      deviceName: s.device_name,
      emails: emails.all(s.id),
    }));
  }

  async deleteSession(id: string): Promise<void> {
    if (!(await this.ctx.sessions.deleteSession(id))) throw notFound("Session not found");
  }

  retryEmails(): number {
    const n = this.ctx.email.retryFailed();
    void this.ctx.email.processDue();
    return n;
  }

  reloadDesigns() {
    return this.ctx.designs.reload();
  }
}
