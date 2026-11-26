import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import request from "supertest";
import { createApp, createContext } from "../src/app.js";
import { loadConfig, type AppConfig } from "../src/config.js";
import type { Ctx } from "../src/context.js";
import type { MailTransport } from "../src/email.js";
import { newSessionId, sha256Hex } from "../src/ids.js";
import { setLogSilent } from "../src/log.js";
import { samplePhoto } from "../src/samples.js";

setLogSilent(true);

export const DEVICE_KEY = "test-device-key-0123456789";
export const ADMIN_PASSWORD = "test-admin-password";
export const REPO_DESIGNS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "designs");

export class FakeMail implements MailTransport {
  sent: { to: string; subject: string; text: string; html: string }[] = [];
  failWith: (Error & { responseCode?: number }) | null = null;
  async sendMail(msg: { to: string; subject: string; text: string; html: string }) {
    if (this.failWith) throw this.failWith;
    this.sent.push(msg);
    return {};
  }
}

export function tempDir(prefix = "pb-test-"): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

export function testConfig(dataDir: string, extra: Record<string, string> = {}): AppConfig {
  return loadConfig({
    DATA_DIR: dataDir,
    DESIGNS_DIR: REPO_DESIGNS,
    DEVICE_API_KEY: DEVICE_KEY,
    ADMIN_PASSWORD,
    PUBLIC_BASE_URL: "https://photos.example.test",
    SMTP_HOST: "smtp.example.test",
    SMTP_FROM_EMAIL: "booth@example.test",
    EMAIL_POLL_MS: "60000",
    ...extra,
  }, dataDir);
}

export interface TestServer {
  ctx: Ctx;
  app: ReturnType<typeof createApp>;
  mail: FakeMail;
  dataDir: string;
  agent: ReturnType<typeof request>;
  /** Simulates a server restart on the same data directory. */
  restart(): TestServer;
}

export function startServer(dataDir = tempDir(), extra: Record<string, string> = {}, mail = new FakeMail()): TestServer {
  const ctx = createContext(testConfig(dataDir, extra), { mailTransport: extra.SMTP_HOST === "" ? null : mail });
  const app = createApp(ctx);
  return {
    ctx,
    app,
    mail,
    dataDir,
    agent: request(app),
    restart() {
      ctx.db.close();
      return startServer(dataDir, extra, mail);
    },
  };
}

export const auth = { Authorization: `Bearer ${DEVICE_KEY}` };

export async function photos(n: number, seed = 0, size = 600): Promise<Buffer[]> {
  return Promise.all(Array.from({ length: n }, (_, i) => samplePhoto(seed + i, size, Math.round(size * 2 / 3))));
}

/** Creates, uploads and completes a session through the HTTP API. */
export async function uploadSession(s: TestServer, opts: { eventId?: string; count?: number } = {}) {
  const id = newSessionId();
  const count = opts.count ?? 3;
  const imgs = await photos(count, Math.floor(Math.random() * 100));
  await s.agent.post("/api/sessions").set(auth).send({ id, eventId: opts.eventId ?? "test-event", eventName: "Test Event", photoCount: count }).expect(201);
  for (let i = 0; i < count; i++) {
    await s.agent.post(`/api/sessions/${id}/photos?index=${i}`).set(auth).set("Content-Type", "image/jpeg").send(imgs[i]).expect(201);
  }
  await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({ sha256: imgs.map(sha256Hex) }).expect(200);
  return { id, imgs };
}
