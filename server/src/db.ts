import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";

export type GalleryMode = "disabled" | "public" | "password";
export type SessionStatus = "uploading" | "complete";
export type EmailStatus = "pending" | "sending" | "sent" | "failed";

export interface EventRow {
  id: string;
  name: string;
  created_at: string;
  gallery_mode: GalleryMode;
  gallery_password_hash: string | null;
  accent_color: string | null;
  default_design: string | null;
}

export interface SessionRow {
  id: string;
  event_id: string;
  photo_count: number;
  status: SessionStatus;
  created_at: string;
  captured_at: string | null;
  completed_at: string | null;
  device_name: string | null;
  design_id: string | null;
}

export interface PhotoRow {
  session_id: string;
  idx: number;
  filename: string;
  sha256: string;
  bytes: number;
  width: number;
  height: number;
  uploaded_at: string;
}

export interface EmailRow {
  id: number;
  session_id: string;
  address: string | null;
  masked: string;
  request_key: string;
  status: EmailStatus;
  attempts: number;
  last_error: string | null;
  next_attempt_at: string;
  created_at: string;
  sent_at: string | null;
}

/** Ordered list of migrations; index + 1 is stored in PRAGMA user_version. */
const MIGRATIONS: string[] = [
  `
  CREATE TABLE events (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    gallery_mode TEXT NOT NULL DEFAULT 'disabled' CHECK (gallery_mode IN ('disabled','public','password')),
    gallery_password_hash TEXT,
    accent_color TEXT,
    default_design TEXT
  );
  CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    photo_count INTEGER NOT NULL CHECK (photo_count BETWEEN 1 AND 12),
    status TEXT NOT NULL DEFAULT 'uploading' CHECK (status IN ('uploading','complete')),
    created_at TEXT NOT NULL,
    captured_at TEXT,
    completed_at TEXT,
    device_name TEXT,
    design_id TEXT
  );
  CREATE INDEX sessions_event ON sessions(event_id, status, completed_at);
  CREATE TABLE photos (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    filename TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    uploaded_at TEXT NOT NULL,
    PRIMARY KEY (session_id, idx)
  );
  CREATE TABLE emails (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    address TEXT,
    masked TEXT NOT NULL,
    request_key TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sending','sent','failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    next_attempt_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    sent_at TEXT
  );
  CREATE INDEX emails_due ON emails(status, next_attempt_at);
  `,
];

export type DB = Database.Database;

export function openDatabase(dataDir: string): DB {
  fs.mkdirSync(dataDir, { recursive: true });
  const db = new Database(path.join(dataDir, "photobooth.sqlite"));
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  migrate(db);
  // A crash while an email was being handed to SMTP leaves it in 'sending';
  // put those back in the queue (at-least-once delivery).
  db.prepare(`UPDATE emails SET status = 'pending' WHERE status = 'sending'`).run();
  return db;
}

function migrate(db: DB): void {
  const version = db.pragma("user_version", { simple: true }) as number;
  for (let v = version; v < MIGRATIONS.length; v++) {
    db.transaction(() => {
      db.exec(MIGRATIONS[v]);
      db.pragma(`user_version = ${v + 1}`);
    })();
  }
}

export const now = (): string => new Date().toISOString();
