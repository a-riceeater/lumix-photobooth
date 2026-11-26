import nodemailer from "nodemailer";
import type { AppConfig } from "./config.js";
import { now, type DB, type EmailRow } from "./db.js";
import { HttpError, notFound } from "./errors.js";
import { isEmail, sha256Hex } from "./ids.js";
import { log, maskEmail } from "./log.js";
import type { SessionService } from "./sessions.js";

/** Anything with nodemailer's sendMail signature (tests inject a fake). */
export interface MailTransport {
  sendMail(msg: { from: string; to: string; subject: string; text: string; html: string }): Promise<unknown>;
}

const MAX_ATTEMPTS = 10;
const EXPIRE_PENDING_MS = 7 * 24 * 3600 * 1000;

/**
 * Persistent email queue. Requests are accepted while a session is still
 * uploading and are delivered once it is complete. Only the fixed gallery
 * message can be sent, to one address per request, with per-session and
 * hourly caps, so the endpoint cannot be used as a relay.
 */
export class EmailService {
  readonly enabled: boolean;
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(
    private readonly db: DB,
    private readonly cfg: AppConfig,
    private readonly sessions: SessionService,
    private readonly transport: MailTransport | null = cfg.smtp
      ? nodemailer.createTransport({
          host: cfg.smtp.host,
          port: cfg.smtp.port,
          secure: cfg.smtp.secure,
          auth: cfg.smtp.user ? { user: cfg.smtp.user, pass: cfg.smtp.password } : undefined,
        })
      : null,
  ) {
    this.enabled = transport !== null;
  }

  enqueue(sessionId: string, addressRaw: unknown): { status: string; duplicate: boolean } {
    if (!this.enabled) throw new HttpError(503, "email_disabled", "Email delivery is not configured on this server");
    const session = this.sessions.getSession(sessionId);
    if (!session) throw notFound("Session not found");
    const address = typeof addressRaw === "string" ? addressRaw.trim() : addressRaw;
    if (!isEmail(address)) throw new HttpError(400, "invalid_email", "Please enter a valid email address");

    const key = sha256Hex(`${sessionId}:${address.toLowerCase()}`);
    const existing = this.db.prepare(`SELECT status FROM emails WHERE request_key = ?`).get(key) as { status: string } | undefined;
    if (existing) return { status: existing.status, duplicate: true };

    const perSession = (this.db.prepare(`SELECT COUNT(*) n FROM emails WHERE session_id = ?`).get(sessionId) as { n: number }).n;
    if (perSession >= this.cfg.emailMaxPerSession) {
      throw new HttpError(429, "rate_limited", "This session has reached its email limit");
    }
    const hourAgo = new Date(Date.now() - 3600_000).toISOString();
    const lastHour = (this.db.prepare(`SELECT COUNT(*) n FROM emails WHERE created_at > ?`).get(hourAgo) as { n: number }).n;
    if (lastHour >= this.cfg.emailMaxPerHour) {
      throw new HttpError(429, "rate_limited", "Too many emails right now; please try again later");
    }
    const ts = now();
    this.db.prepare(
      `INSERT INTO emails (session_id, address, masked, request_key, status, next_attempt_at, created_at)
       VALUES (?, ?, ?, ?, 'pending', ?, ?)`,
    ).run(sessionId, address, maskEmail(address), key, ts, ts);
    log.info("email queued", { session: sessionId.slice(0, 6) });
    queueMicrotask(() => void this.processDue());
    return { status: "pending", duplicate: false };
  }

  start(): void {
    if (!this.enabled || this.timer) return;
    this.timer = setInterval(() => void this.processDue(), this.cfg.emailPollMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Sends every due email whose session is complete. Safe to call often. */
  async processDue(): Promise<number> {
    if (!this.transport || this.running) return 0;
    this.running = true;
    let sent = 0;
    try {
      const expireBefore = new Date(Date.now() - EXPIRE_PENDING_MS).toISOString();
      this.db.prepare(
        `UPDATE emails SET status = 'failed', address = NULL, last_error = 'session never completed'
         WHERE status = 'pending' AND created_at < ? AND session_id IN (SELECT id FROM sessions WHERE status <> 'complete')`,
      ).run(expireBefore);
      const due = this.db.prepare(
        `SELECT e.* FROM emails e JOIN sessions s ON s.id = e.session_id
         WHERE e.status = 'pending' AND e.next_attempt_at <= ? AND s.status = 'complete' AND e.address IS NOT NULL
         ORDER BY e.next_attempt_at LIMIT 20`,
      ).all(now()) as EmailRow[];
      for (const row of due) {
        if (await this.deliver(row)) sent++;
      }
    } finally {
      this.running = false;
    }
    return sent;
  }

  private async deliver(row: EmailRow): Promise<boolean> {
    const claimed = this.db.prepare(`UPDATE emails SET status = 'sending' WHERE id = ? AND status = 'pending'`).run(row.id);
    if (claimed.changes === 0) return false;
    const session = this.sessions.getSession(row.session_id)!;
    const event = this.sessions.getEvent(session.event_id)!;
    const msg = renderGalleryEmail(event.name, this.sessions.galleryUrl(session.id));
    try {
      await this.transport!.sendMail({
        from: `"${this.cfg.smtp!.fromName.replace(/"/g, "")}" <${this.cfg.smtp!.fromEmail}>`,
        to: row.address!,
        ...msg,
      });
      // The address is no longer needed once delivered.
      this.db.prepare(`UPDATE emails SET status = 'sent', sent_at = ?, address = NULL, attempts = attempts + 1, last_error = NULL WHERE id = ?`)
        .run(now(), row.id);
      log.info("email sent", { session: session.id.slice(0, 6), id: row.id });
      return true;
    } catch (e) {
      const err = e as { responseCode?: number; code?: string; message?: string };
      const attempts = row.attempts + 1;
      const permanent = (err.responseCode !== undefined && err.responseCode >= 500 && err.responseCode !== 554) || attempts >= MAX_ATTEMPTS;
      const delay = Math.min(30_000 * 2 ** (attempts - 1), 3600_000);
      const reason = String(err.responseCode ?? err.code ?? "error") + ": " + String(err.message ?? "").split("\n")[0].slice(0, 200);
      this.db.prepare(`UPDATE emails SET status = ?, attempts = ?, last_error = ?, next_attempt_at = ? WHERE id = ?`)
        .run(permanent ? "failed" : "pending", attempts, reason, new Date(Date.now() + delay).toISOString(), row.id);
      log.warn(permanent ? "email failed permanently" : "email failed, will retry", { id: row.id, attempts, code: err.responseCode ?? err.code });
      return false;
    }
  }

  /** Admin: requeue failed emails that still have an address. */
  retryFailed(): number {
    return this.db.prepare(`UPDATE emails SET status = 'pending', attempts = 0, next_attempt_at = ? WHERE status = 'failed' AND address IS NOT NULL`)
      .run(now()).changes;
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&#39;", '"': "&quot;" })[c]!);
}

export function renderGalleryEmail(eventName: string, url: string): { subject: string; text: string; html: string } {
  const name = escapeHtml(eventName);
  const href = escapeHtml(url);
  const subject = `Your photos from ${eventName.replace(/[\r\n]/g, " ")}`;
  const text = `Thanks for stopping by the photo booth at ${eventName}!\n\n` +
    `View and download your photos here:\n${url}\n\n` +
    `You can choose a photo strip design and download every picture from that page.\n`;
  const html = `<!doctype html><html><body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#18181b">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:32px 16px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px">
<tr><td style="font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#71717a">${name}</td></tr>
<tr><td style="padding:12px 0 8px;font-size:24px;font-weight:600">Your photos are ready</td></tr>
<tr><td style="padding:0 0 24px;font-size:16px;line-height:1.5;color:#3f3f46">Thanks for stopping by the photo booth! Your pictures and photo strip are waiting for you.</td></tr>
<tr><td align="center" style="padding:0 0 24px"><a href="${href}" style="display:inline-block;background:#18181b;color:#ffffff;text-decoration:none;font-size:16px;font-weight:600;padding:14px 28px;border-radius:8px">View your photos</a></td></tr>
<tr><td style="font-size:13px;line-height:1.5;color:#71717a">Or open this link: <a href="${href}" style="color:#3f3f46;word-break:break-all">${href}</a></td></tr>
</table></td></tr></table></body></html>`;
  return { subject, text, html };
}
