import fsp from "node:fs/promises";
import path from "node:path";
import sharp, { type Metadata } from "sharp";
import type { AppConfig } from "./config.js";
import { now, type DB, type EventRow, type PhotoRow, type SessionRow } from "./db.js";
import { badRequest, conflict, HttpError, notFound } from "./errors.js";
import { isDesignId, isEventId, isSessionId, sha256Hex } from "./ids.js";
import { log } from "./log.js";
import { Storage } from "./storage.js";

export interface CreateSessionInput {
  id: unknown;
  eventId: unknown;
  eventName?: unknown;
  photoCount: unknown;
  capturedAt?: unknown;
  deviceName?: unknown;
  designId?: unknown;
}

export interface PhotoResult {
  index: number;
  sha256: string;
  bytes: number;
  width: number;
  height: number;
  duplicate: boolean;
}

const MAX_NAME = 120;

function cleanText(v: unknown, field: string, max = MAX_NAME): string | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string") throw badRequest(`${field} must be a string`);
  const t = v.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  if (t.length > max) throw badRequest(`${field} must be at most ${max} characters`);
  return t || null;
}

export class SessionService {
  constructor(
    private readonly db: DB,
    private readonly storage: Storage,
    private readonly cfg: AppConfig,
  ) {}

  // -- events ----------------------------------------------------------------

  getEvent(id: string): EventRow | undefined {
    return this.db.prepare(`SELECT * FROM events WHERE id = ?`).get(id) as EventRow | undefined;
  }

  /** Creates the event on first use; never changes an existing event's settings. */
  ensureEvent(id: string, name: string | null): EventRow {
    if (!isEventId(id)) throw badRequest("eventId must be a lowercase slug (letters, digits, dashes)");
    this.db.prepare(
      `INSERT INTO events (id, name, created_at, gallery_mode) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING`,
    ).run(id, name ?? id, now(), this.cfg.publicEventGalleryDefault ? "public" : "disabled");
    return this.getEvent(id)!;
  }

  // -- sessions --------------------------------------------------------------

  getSession(id: string): SessionRow | undefined {
    if (!isSessionId(id)) return undefined;
    return this.db.prepare(`SELECT * FROM sessions WHERE id = ?`).get(id) as SessionRow | undefined;
  }

  requireSession(id: string): SessionRow {
    const s = this.getSession(id);
    if (!s) throw notFound("Session not found");
    return s;
  }

  /** Idempotent: repeating the same request returns the existing session. */
  createSession(input: CreateSessionInput): { session: SessionRow; created: boolean } {
    if (!isSessionId(input.id)) throw badRequest("id must be 22-64 base64url characters (128+ random bits)");
    if (!isEventId(input.eventId)) throw badRequest("eventId must be a lowercase slug (letters, digits, dashes)");
    const photoCount = input.photoCount;
    if (typeof photoCount !== "number" || !Number.isInteger(photoCount) || photoCount < 1 || photoCount > 12) {
      throw badRequest("photoCount must be an integer from 1 to 12");
    }
    let capturedAt: string | null = null;
    if (input.capturedAt !== undefined && input.capturedAt !== null) {
      const d = new Date(String(input.capturedAt));
      if (Number.isNaN(d.getTime())) throw badRequest("capturedAt must be an ISO 8601 date");
      capturedAt = d.toISOString();
    }
    const designId = input.designId === undefined || input.designId === null ? null : input.designId;
    if (designId !== null && !isDesignId(designId)) throw badRequest("designId is not a valid design id");
    const deviceName = cleanText(input.deviceName, "deviceName");
    const eventName = cleanText(input.eventName, "eventName");

    const existing = this.getSession(input.id);
    if (existing) {
      if (existing.event_id !== input.eventId || existing.photo_count !== photoCount) {
        throw conflict("A different session with this id already exists");
      }
      return { session: existing, created: false };
    }
    return this.db.transaction(() => {
      this.ensureEvent(input.eventId as string, eventName);
      this.db.prepare(
        `INSERT INTO sessions (id, event_id, photo_count, status, created_at, captured_at, device_name, design_id)
         VALUES (?, ?, ?, 'uploading', ?, ?, ?, ?)`,
      ).run(input.id, input.eventId, photoCount, now(), capturedAt, deviceName, designId);
      log.info("session created", { session: (input.id as string).slice(0, 6), event: input.eventId });
      return { session: this.getSession(input.id as string)!, created: true };
    })();
  }

  photos(sessionId: string): PhotoRow[] {
    return this.db.prepare(`SELECT * FROM photos WHERE session_id = ? ORDER BY idx`).all(sessionId) as PhotoRow[];
  }

  photo(sessionId: string, index: number): PhotoRow | undefined {
    return this.db.prepare(`SELECT * FROM photos WHERE session_id = ? AND idx = ?`).get(sessionId, index) as PhotoRow | undefined;
  }

  /**
   * Stores one original JPEG byte-for-byte (never re-encoded).
   * Idempotent: the same bytes for the same index return `duplicate: true`;
   * different bytes for an index that already has a photo are rejected (409),
   * so an original is never overwritten.
   */
  async addPhoto(sessionId: string, indexRaw: unknown, body: Buffer, declaredSha?: unknown): Promise<PhotoResult> {
    const session = this.requireSession(sessionId);
    const index = typeof indexRaw === "string" && /^\d{1,2}$/.test(indexRaw) ? Number(indexRaw) : indexRaw;
    if (typeof index !== "number" || !Number.isInteger(index) || index < 0 || index >= session.photo_count) {
      throw badRequest(`index must be an integer from 0 to ${session.photo_count - 1}`);
    }
    if (!Buffer.isBuffer(body) || body.length === 0) throw badRequest("Request body must be the JPEG file (Content-Type: image/jpeg)");
    const sha = sha256Hex(body);
    if (declaredSha !== undefined && declaredSha !== null && declaredSha !== "") {
      if (typeof declaredSha !== "string" || !/^[0-9a-fA-F]{64}$/.test(declaredSha)) throw badRequest("sha256 must be 64 hex characters");
      if (declaredSha.toLowerCase() !== sha) {
        throw new HttpError(422, "checksum_mismatch", "Uploaded bytes do not match the declared sha256 (transfer corrupted?)");
      }
    }

    const existing = this.photo(sessionId, index);
    if (existing) {
      if (existing.sha256 === sha) return { ...this.toResult(existing), duplicate: true };
      throw conflict(`Photo ${index} of this session already exists with different content`, { sha256: existing.sha256 });
    }
    if (session.status === "complete") throw conflict("Session is already complete");

    const meta = await this.validateJpeg(body);
    const dest = this.storage.originalPath(session.event_id, sessionId, index);
    const tmp = this.storage.tempPath(".jpg");
    await fsp.writeFile(tmp, body, { flag: "wx" });
    const handle = await fsp.open(tmp, "r+");
    await handle.sync();
    await handle.close();
    if (!(await this.storage.publishNoClobber(tmp, dest))) {
      // A file without a DB row: a previous attempt crashed between the two
      // steps. Keep it if identical, otherwise move it aside (never delete).
      const onDisk = await fsp.readFile(dest);
      if (sha256Hex(onDisk) !== sha) {
        const aside = path.join(path.dirname(dest), `.orphan-${Date.now()}-${path.basename(dest)}`);
        await fsp.rename(dest, aside);
        log.warn("moved orphaned original aside", { session: sessionId.slice(0, 6), index });
        const retry = this.storage.tempPath(".jpg");
        await fsp.writeFile(retry, body, { flag: "wx" });
        if (!(await this.storage.publishNoClobber(retry, dest))) throw conflict("Concurrent upload of the same photo");
      }
    }
    const row: PhotoRow = {
      session_id: sessionId,
      idx: index,
      filename: Storage.originalName(index),
      sha256: sha,
      bytes: body.length,
      width: meta.width,
      height: meta.height,
      uploaded_at: now(),
    };
    const inserted = this.db.prepare(
      `INSERT INTO photos (session_id, idx, filename, sha256, bytes, width, height, uploaded_at)
       VALUES (@session_id, @idx, @filename, @sha256, @bytes, @width, @height, @uploaded_at)
       ON CONFLICT(session_id, idx) DO NOTHING`,
    ).run(row);
    if (inserted.changes === 0) {
      // Lost a race with an identical concurrent request.
      const again = this.photo(sessionId, index)!;
      if (again.sha256 !== sha) throw conflict(`Photo ${index} already exists with different content`);
      return { ...this.toResult(again), duplicate: true };
    }
    log.info("photo stored", { session: sessionId.slice(0, 6), index, bytes: body.length });
    return { ...this.toResult(row), duplicate: false };
  }

  private toResult(r: PhotoRow): Omit<PhotoResult, "duplicate"> {
    return { index: r.idx, sha256: r.sha256, bytes: r.bytes, width: r.width, height: r.height };
  }

  private async validateJpeg(body: Buffer): Promise<{ width: number; height: number }> {
    if (body.length < 4 || body[0] !== 0xff || body[1] !== 0xd8 || body[2] !== 0xff) {
      throw new HttpError(415, "unsupported_media_type", "Only JPEG photos are accepted");
    }
    let meta: Metadata;
    try {
      meta = await sharp(body).metadata();
    } catch {
      throw new HttpError(415, "unsupported_media_type", "The file is not a readable JPEG");
    }
    if (meta.format !== "jpeg" || !meta.width || !meta.height) {
      throw new HttpError(415, "unsupported_media_type", "The file is not a readable JPEG");
    }
    const max = this.cfg.maxImageDimension;
    if (meta.width > max || meta.height > max) throw badRequest(`Image dimensions exceed ${max}px`);
    if (meta.width < 16 || meta.height < 16) throw badRequest("Image is too small");
    return { width: meta.width, height: meta.height };
  }

  /** Marks the session complete once every photo is present. Idempotent. */
  complete(sessionId: string, expected?: unknown): SessionRow {
    const session = this.requireSession(sessionId);
    const photos = this.photos(sessionId);
    const missing = this.missing(session, photos);
    if (missing.length) throw conflict("Session is missing photos", { missing });
    if (expected !== undefined) {
      if (!Array.isArray(expected) || expected.length !== session.photo_count) {
        throw badRequest(`sha256 must be an array of ${session.photo_count} checksums`);
      }
      const mismatched = photos.filter((p) => String(expected[p.idx]).toLowerCase() !== p.sha256).map((p) => p.idx);
      if (mismatched.length) throw conflict("Stored photos differ from the device's copies", { mismatched });
    }
    if (session.status !== "complete") {
      this.db.prepare(`UPDATE sessions SET status = 'complete', completed_at = ? WHERE id = ? AND status <> 'complete'`)
        .run(now(), sessionId);
      log.info("session complete", { session: sessionId.slice(0, 6) });
    }
    return this.getSession(sessionId)!;
  }

  missing(session: SessionRow, photos = this.photos(session.id)): number[] {
    const have = new Set(photos.map((p) => p.idx));
    return Array.from({ length: session.photo_count }, (_, i) => i).filter((i) => !have.has(i));
  }

  status(sessionId: string) {
    const session = this.requireSession(sessionId);
    const photos = this.photos(sessionId);
    return {
      id: session.id,
      eventId: session.event_id,
      status: session.status,
      photoCount: session.photo_count,
      photos: photos.map((p) => ({ index: p.idx, sha256: p.sha256, bytes: p.bytes })),
      missing: this.missing(session, photos),
      galleryUrl: this.galleryUrl(session.id),
    };
  }

  galleryUrl(sessionId: string): string {
    return `${this.cfg.publicBaseUrl}/s/${sessionId}`;
  }

  async deleteSession(sessionId: string): Promise<boolean> {
    const s = this.getSession(sessionId);
    if (!s) return false;
    this.db.prepare(`DELETE FROM sessions WHERE id = ?`).run(sessionId);
    await this.storage.removeSession(s.event_id, sessionId);
    log.info("session deleted", { session: sessionId.slice(0, 6) });
    return true;
  }

  /** Completed sessions of an event, newest first (for the event gallery). */
  completedSessions(eventId: string, limit: number, offset: number): SessionRow[] {
    return this.db.prepare(
      `SELECT * FROM sessions WHERE event_id = ? AND status = 'complete'
       ORDER BY completed_at DESC, id LIMIT ? OFFSET ?`,
    ).all(eventId, limit, offset) as SessionRow[];
  }
}
