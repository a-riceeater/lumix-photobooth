import express, { Router } from "express";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.js";
import { isEventId, isSessionId } from "../ids.js";
import { hashPassword, rateLimit, setCookie, verifyPassword } from "../middleware.js";
import { galleryAccess, galleryCookieName } from "./events.js";

const GALLERY_TTL = 30 * 24 * 3600;

/**
 * Adds a content fingerprint to every /assets/ link ("/assets/admin.js?v=1a2b3c4d").
 * CDNs such as Cloudflare cache assets for hours regardless of our headers;
 * a changed file gets a new URL, so a deploy is visible on the next page load.
 */
export function versionAssetLinks(html: string, publicDir: string): string {
  return html.replace(/(["'])\/assets\/([\w.-]+)(\?v=[\w]+)?\1/g, (whole, quote: string, file: string) => {
    try {
      const hash = createHash("sha1").update(fs.readFileSync(path.join(publicDir, "assets", file))).digest("hex").slice(0, 10);
      return `${quote}/assets/${file}?v=${hash}${quote}`;
    } catch {
      return whole;
    }
  });
}

/** Reads public/<name>.html once per process (or every time in development). */
function page(publicDir: string, name: string): () => string {
  let cached: string | null = null;
  return () => {
    if (cached === null || process.env.NODE_ENV === "development") {
      cached = versionAssetLinks(fs.readFileSync(path.join(publicDir, `${name}.html`), "utf8"), publicDir);
    }
    return cached;
  };
}

// Equalises timing between wrong-event and wrong-password attempts.
const DUMMY_HASH = hashPassword("not-the-password");

export function pagesRouter(ctx: Ctx, publicDir: string): Router {
  const r = Router();
  const sessionPage = page(publicDir, "session");
  const eventPage = page(publicDir, "event");
  const passwordPage = page(publicDir, "gallery-password");
  const notFoundPage = page(publicDir, "404");
  const html = (res: express.Response, body: string, status = 200) => {
    res.status(status).type("html").setHeader("Cache-Control", "no-cache");
    res.send(body);
  };

  r.get("/", (_req, res) => html(res, page(publicDir, "index")()));

  // Private session links work whether or not the event gallery is enabled.
  r.get("/s/:id", (req, res) => {
    if (!isSessionId(req.params.id)) return html(res, notFoundPage(), 404);
    html(res, sessionPage());
  });

  r.get(["/gallery", "/gallery/"], (_req, res) => html(res, notFoundPage(), 404));

  r.get("/gallery/:eventId", (req, res) => {
    const id = req.params.eventId;
    const event = isEventId(id) ? ctx.sessions.getEvent(id) : undefined;
    const access = galleryAccess(ctx, req, event);
    if (access === "disabled") return html(res, notFoundPage(), 404);
    if (access === "password_required") return html(res, passwordPage().replaceAll("{{eventId}}", id), 401);
    html(res, eventPage());
  });

  r.post("/gallery/:eventId/login",
    rateLimit({ windowMs: 60_000, max: 10, scope: "gallery-login" }),
    express.urlencoded({ extended: false, limit: "4kb" }),
    (req, res) => {
      const id = String(req.params.eventId);
      const event = isEventId(id) ? ctx.sessions.getEvent(id) : undefined;
      const password = typeof req.body?.password === "string" ? req.body.password : "";
      const ok = event?.gallery_mode === "password"
        ? verifyPassword(password, event.gallery_password_hash)
        : (verifyPassword(password, DUMMY_HASH), false);
      if (!event || !ok) return res.redirect(303, `/gallery/${encodeURIComponent(id)}?error=1`);
      setCookie(req, res, galleryCookieName(id), ctx.cookies.sign(`${id}:${event.gallery_password_hash}`, GALLERY_TTL), GALLERY_TTL);
      res.redirect(303, `/gallery/${id}`);
    });

  r.get(["/admin", "/admin/"], (_req, res) => html(res, page(publicDir, "admin")()));

  return r;
}
