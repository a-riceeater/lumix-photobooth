import fsp from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
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
}
