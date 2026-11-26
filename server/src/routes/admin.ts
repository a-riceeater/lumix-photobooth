import express, { Router, type NextFunction, type Request, type Response } from "express";
import { AdminOps } from "../adminOps.js";
import type { Ctx } from "../context.js";
import { HttpError } from "../errors.js";
import { safeEqual } from "../ids.js";
import { rateLimit, readCookie, setCookie } from "../middleware.js";
import { FONT_CHOICES, SINGLE_COLUMN_DEFAULTS } from "../themeBuilder.js";
import { ThemeService } from "../themes.js";

const ADMIN_COOKIE = "pb_admin";
const ADMIN_TTL = 12 * 3600;

export function isAdmin(ctx: Ctx, req: Request): boolean {
  if (ctx.cookies.verify(readCookie(req, ADMIN_COOKIE)) === "admin") return true;
  const header = req.get("authorization") ?? "";
  if (header.startsWith("Basic ")) {
    const decoded = Buffer.from(header.slice(6), "base64").toString();
    const password = decoded.slice(decoded.indexOf(":") + 1);
    return safeEqual(password, ctx.cfg.adminPassword);
  }
  return false;
}

/** /admin login/logout (form posts) */
export function adminPagesRouter(ctx: Ctx): Router {
  const r = Router();
  const form = express.urlencoded({ extended: false, limit: "4kb" });
  r.post("/login", rateLimit({ windowMs: 60_000, max: 10, scope: "admin-login" }), form, (req, res) => {
    if (typeof req.body?.password === "string" && safeEqual(req.body.password, ctx.cfg.adminPassword)) {
      setCookie(req, res, ADMIN_COOKIE, ctx.cookies.sign("admin", ADMIN_TTL), ADMIN_TTL);
      return res.redirect(303, "/admin/");
    }
    res.redirect(303, "/admin/?error=1");
  });
  r.post("/logout", (req, res) => {
    setCookie(req, res, ADMIN_COOKIE, "", 0);
    res.redirect(303, "/admin/");
  });
  return r;
}

/** /api/admin JSON API */
export function adminApiRouter(ctx: Ctx): Router {
  const r = Router();
  const ops = new AdminOps(ctx);
  r.use((req: Request, _res: Response, next: NextFunction) => {
    if (!isAdmin(ctx, req)) return next(new HttpError(401, "unauthorized", "Admin login required"));
    // Mutations must be JSON: HTML forms on other sites cannot send that.
    if (!["GET", "HEAD"].includes(req.method) && !req.is("application/json")) {
      return next(new HttpError(415, "unsupported_media_type", "Use Content-Type: application/json"));
    }
    next();
  });
  // Theme uploads carry images as base64, so they get a larger body limit.
  r.use("/themes", express.json({ limit: "60mb" }));
  r.use(express.json({ limit: "16kb" }));

  const themes = new ThemeService(ctx);
  r.get("/themes", (_req, res) => {
    res.json({ ...themes.list(), defaults: SINGLE_COLUMN_DEFAULTS, fonts: FONT_CHOICES });
  });
  r.post("/themes/preview", async (req, res) => {
    const { jpeg, warnings } = await themes.preview(req.body?.params, req.body ?? {}, req.body?.id);
    res.setHeader("Cache-Control", "no-store");
    // Header values must be ASCII-safe: send the warnings URI-encoded.
    if (warnings.length) res.setHeader("X-Theme-Warnings", encodeURIComponent(warnings.join(" ")));
    res.type("jpeg").send(jpeg);
  });
  r.post("/themes", async (req, res) => {
    res.status(req.body?.id ? 200 : 201).json({ id: await themes.save(req.body ?? {}) });
  });
  r.patch("/themes/:id", async (req, res) => {
    if (typeof req.body?.enabled !== "boolean") throw new HttpError(400, "bad_request", "Send {\"enabled\": true|false}");
    await themes.setEnabled(req.params.id, req.body.enabled);
    res.json({ ok: true });
  });
  r.delete("/themes/:id", async (req, res) => {
    await themes.remove(req.params.id);
    res.json({ deleted: true });
  });

  r.get("/overview", (_req, res) => {
    res.json(ops.overview());
  });
  r.post("/events", (req, res) => {
    res.status(201).json(ops.publicEvent(ops.createEvent(req.body?.id, req.body?.name)));
  });
  r.patch("/events/:id", (req, res) => {
    res.json(ops.publicEvent(ops.updateEvent(String(req.params.id), req.body ?? {})));
  });
  r.delete("/events/:id", async (req, res) => {
    if (req.body?.confirm !== req.params.id) throw new HttpError(400, "confirm_required", "Send {\"confirm\": \"<event id>\"} to delete an event");
    await ops.deleteEvent(String(req.params.id));
    res.json({ deleted: true });
  });
  r.get("/events/:id/sessions", (req, res) => {
    res.json({
      sessions: ops.sessions(String(req.params.id), {
        status: req.query.status as string | undefined,
        limit: Number(req.query.limit) || undefined,
        offset: Number(req.query.offset) || undefined,
      }),
    });
  });
  r.delete("/sessions/:id", async (req, res) => {
    await ops.deleteSession(String(req.params.id));
    res.json({ deleted: true });
  });
  r.post("/emails/retry", (_req, res) => {
    res.json({ requeued: ops.retryEmails() });
  });
  r.post("/designs/reload", (_req, res) => {
    res.json(ops.reloadDesigns());
  });
  return r;
}
