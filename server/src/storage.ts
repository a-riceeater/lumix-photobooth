import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { isEventId, isSessionId } from "./ids.js";

/**
 * Filesystem layout:
 *   DATA_DIR/events/<eventId>/sessions/<sessionId>/{originals,thumbnails,generated}
 * Every path is built from validated IDs only, and the result is checked to be
 * inside DATA_DIR, so request input can never escape it.
 */
export class Storage {
  readonly root: string;
  readonly tmpDir: string;

  constructor(dataDir: string) {
    this.root = path.resolve(dataDir);
    this.tmpDir = path.join(this.root, "tmp");
    fs.mkdirSync(path.join(this.root, "events"), { recursive: true });
    fs.mkdirSync(this.tmpDir, { recursive: true });
  }

  sessionDir(eventId: string, sessionId: string): string {
    if (!isEventId(eventId) || !isSessionId(sessionId)) throw new Error("invalid id");
    return this.inside(path.join(this.root, "events", eventId, "sessions", sessionId));
  }

  originalsDir(eventId: string, sessionId: string): string {
    return path.join(this.sessionDir(eventId, sessionId), "originals");
  }

  thumbnailsDir(eventId: string, sessionId: string): string {
    return path.join(this.sessionDir(eventId, sessionId), "thumbnails");
  }

  generatedDir(eventId: string, sessionId: string): string {
    return path.join(this.sessionDir(eventId, sessionId), "generated");
  }

  /** 0-based index -> "01.jpg". */
  static originalName(index: number): string {
    return `${String(index + 1).padStart(2, "0")}.jpg`;
  }

  originalPath(eventId: string, sessionId: string, index: number): string {
    return path.join(this.originalsDir(eventId, sessionId), Storage.originalName(index));
  }

  private inside(p: string): string {
    const resolved = path.resolve(p);
    if (resolved !== this.root && !resolved.startsWith(this.root + path.sep)) {
      throw new Error("path escapes data directory");
    }
    return resolved;
  }

  /** A unique temp file path on the same filesystem as the data (for renames). */
  tempPath(suffix = ""): string {
    return path.join(this.tmpDir, `${Date.now()}-${randomBytes(6).toString("hex")}${suffix}`);
  }

  /**
   * Atomically publishes `tmp` at `dest` without ever replacing an existing
   * file: link() fails with EEXIST if dest exists. Returns false in that case
   * (tmp is removed either way).
   */
  async publishNoClobber(tmp: string, dest: string): Promise<boolean> {
    await fsp.mkdir(path.dirname(dest), { recursive: true });
    try {
      await fsp.link(tmp, dest);
      return true;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "EEXIST") return false;
      throw e;
    } finally {
      await fsp.rm(tmp, { force: true });
    }
  }

  /** Atomic write that may replace (for derived/cached files only). */
  async writeReplace(dest: string, data: Buffer): Promise<void> {
    await fsp.mkdir(path.dirname(dest), { recursive: true });
    const tmp = this.tempPath(path.extname(dest));
    await fsp.writeFile(tmp, data);
    await fsp.rename(tmp, dest);
  }

  async removeSession(eventId: string, sessionId: string): Promise<void> {
    await fsp.rm(this.sessionDir(eventId, sessionId), { recursive: true, force: true });
  }

  async removeEvent(eventId: string): Promise<void> {
    if (!isEventId(eventId)) throw new Error("invalid id");
    await fsp.rm(this.inside(path.join(this.root, "events", eventId)), { recursive: true, force: true });
  }

  /** Deletes stale temp files left by a crash. */
  async cleanTemp(maxAgeMs = 60 * 60 * 1000): Promise<void> {
    const cutoff = Date.now() - maxAgeMs;
    for (const name of await fsp.readdir(this.tmpDir)) {
      const p = path.join(this.tmpDir, name);
      const st = await fsp.stat(p).catch(() => null);
      if (st && st.mtimeMs < cutoff) await fsp.rm(p, { force: true });
    }
  }
}

export async function fileExists(p: string): Promise<boolean> {
  try {
    await fsp.access(p);
    return true;
  } catch {
    return false;
  }
}
