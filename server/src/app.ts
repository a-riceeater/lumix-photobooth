import express, { type Express } from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { AppConfig } from "./config.js";
import type { Ctx } from "./context.js";
import { openDatabase } from "./db.js";
import { DesignRegistry } from "./designs.js";
import { EmailService, type MailTransport } from "./email.js";
import { ImageService } from "./images.js";
import { apiNotFound, CookieSigner, errorHandler } from "./middleware.js";
import { adminApiRouter, adminPagesRouter } from "./routes/admin.js";
import { apiRouter } from "./routes/api.js";
import { pagesRouter } from "./routes/pages.js";
import { SessionService } from "./sessions.js";
import { Storage } from "./storage.js";

/** server/public, both from src/ (tsx) and dist/ (compiled). */
export const PUBLIC_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "public");

export interface AppOptions {
  /** Inject a fake SMTP transport (tests). `null` disables email. */
  mailTransport?: MailTransport | null;
}

export function createContext(cfg: AppConfig, opts: AppOptions = {}): Ctx {
  const db = openDatabase(cfg.dataDir);
  const storage = new Storage(cfg.photosDir);
  const sessions = new SessionService(db, storage, cfg);
  const email = opts.mailTransport === undefined
    ? new EmailService(db, cfg, sessions)
    : new EmailService(db, cfg, sessions, opts.mailTransport);
  return {
    cfg,
    db,
    storage,
    sessions,
    images: new ImageService(storage),
    designs: new DesignRegistry(cfg.designsDir),
    email,
    cookies: new CookieSigner(`${cfg.adminPassword}:${cfg.deviceApiKey}`),
  };
}

export function createApp(ctx: Ctx): Express {
  const app = express();
  app.disable("x-powered-by");
  app.set("trust proxy", ctx.cfg.trustProxy);
  app.set("etag", "strong");

  app.use((_req, res, next) => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader(
      "Content-Security-Policy",
      "default-src 'self'; img-src 'self' data: blob:; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    );
    next();
  });

  app.use("/api/admin", adminApiRouter(ctx));
  app.use("/api", apiRouter(ctx));
  app.use("/api", apiNotFound);
  app.use("/admin", adminPagesRouter(ctx));
  // Revalidate on every load (cheap 304 via ETag) so updates show up immediately.
  app.use("/assets", express.static(path.join(PUBLIC_DIR, "assets"), { maxAge: 0, index: false, etag: true, lastModified: true }));
  app.use(pagesRouter(ctx, PUBLIC_DIR));
  app.use((req, res) => {
    res.status(404).type("html").sendFile(path.join(PUBLIC_DIR, "404.html"));
  });
  app.use(errorHandler);
  return app;
}
