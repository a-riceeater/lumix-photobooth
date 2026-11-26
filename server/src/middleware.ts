import { createHmac, randomBytes, scryptSync, timingSafeEqual } from "node:crypto";
import type { NextFunction, Request, Response } from "express";
import { HttpError } from "./errors.js";
import { safeEqual } from "./ids.js";
import { log } from "./log.js";

/** Requires `Authorization: Bearer <DEVICE_API_KEY>` (or X-Device-Key). */
export function requireDevice(apiKey: string) {
  return (req: Request, _res: Response, next: NextFunction) => {
    const header = req.get("authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : (req.get("x-device-key") ?? "");
    if (!token || !safeEqual(token, apiKey)) return next(new HttpError(401, "unauthorized", "Missing or invalid device API key"));
    next();
  };
}

/** Fixed-window in-memory rate limiter keyed by client IP (plus a scope). */
export function rateLimit(opts: { windowMs: number; max: number; scope: string }) {
  const hits = new Map<string, { count: number; reset: number }>();
  setInterval(() => {
    const t = Date.now();
    for (const [k, v] of hits) if (v.reset < t) hits.delete(k);
  }, opts.windowMs).unref();
  return (req: Request, res: Response, next: NextFunction) => {
    const key = `${opts.scope}:${req.ip}`;
    const t = Date.now();
    let entry = hits.get(key);
    if (!entry || entry.reset < t) {
      entry = { count: 0, reset: t + opts.windowMs };
      hits.set(key, entry);
    }
    entry.count++;
    if (entry.count > opts.max) {
      res.setHeader("Retry-After", String(Math.ceil((entry.reset - t) / 1000)));
      return next(new HttpError(429, "rate_limited", "Too many requests; please slow down"));
    }
    next();
  };
}

// -- signed cookies (admin login, event gallery passwords) ---------------------

export class CookieSigner {
  private readonly key: Buffer;
  constructor(secret: string) {
    this.key = createHmac("sha256", "photobooth-cookie").update(secret).digest();
  }
  sign(value: string, maxAgeSec: number): string {
    const exp = Math.floor(Date.now() / 1000) + maxAgeSec;
    const payload = `${Buffer.from(value).toString("base64url")}.${exp}`;
    return `${payload}.${createHmac("sha256", this.key).update(payload).digest("base64url")}`;
  }
  verify(token: string | undefined): string | null {
    if (!token) return null;
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = `${parts[0]}.${parts[1]}`;
    const expected = createHmac("sha256", this.key).update(payload).digest();
    const given = Buffer.from(parts[2], "base64url");
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
    if (Number(parts[1]) < Date.now() / 1000) return null;
    return Buffer.from(parts[0], "base64url").toString();
  }
}

export function readCookie(req: Request, name: string): string | undefined {
  const header = req.get("cookie");
  if (!header) return undefined;
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return undefined;
}

export function setCookie(req: Request, res: Response, name: string, value: string, maxAgeSec: number, cookiePath = "/"): void {
  const secure = req.secure ? "; Secure" : "";
  res.append("Set-Cookie", `${name}=${encodeURIComponent(value)}; Path=${cookiePath}; Max-Age=${maxAgeSec}; HttpOnly; SameSite=Lax${secure}`);
}

// -- password hashing (event gallery passwords) ---------------------------------

export function hashPassword(password: string): string {
  const salt = randomBytes(16);
  const hash = scryptSync(password, salt, 32);
  return `scrypt$${salt.toString("base64url")}$${hash.toString("base64url")}`;
}

export function verifyPassword(password: string, stored: string | null): boolean {
  if (!stored) return false;
  const [scheme, salt, hash] = stored.split("$");
  if (scheme !== "scrypt" || !salt || !hash) return false;
  const expected = Buffer.from(hash, "base64url");
  const actual = scryptSync(password, Buffer.from(salt, "base64url"), expected.length);
  return timingSafeEqual(actual, expected);
}

// -- errors --------------------------------------------------------------------

export function apiNotFound(_req: Request, _res: Response, next: NextFunction) {
  next(new HttpError(404, "not_found", "Unknown API endpoint"));
}

export function errorHandler(err: unknown, req: Request, res: Response, _next: NextFunction) {
  let status = 500;
  let body: Record<string, unknown> = { error: "internal_error", message: "Something went wrong" };
  const e = err as { status?: number; type?: string; message?: string };
  if (err instanceof HttpError) {
    status = err.status;
    body = { error: err.code, message: err.message, ...(err.details ?? {}) };
  } else if (e?.type === "entity.too.large") {
    status = 413;
    body = { error: "payload_too_large", message: "The upload is larger than the server allows" };
  } else if (e?.type === "entity.parse.failed") {
    status = 400;
    body = { error: "bad_request", message: "Malformed JSON body" };
  } else {
    log.error("unhandled error", { path: req.path, error: e?.message ?? String(err) });
  }
  if (res.headersSent) return;
  if (req.path.startsWith("/api/") || req.accepts(["json", "html"]) === "json") {
    res.status(status).json(body);
  } else {
    res.status(status).type("html").send(`<!doctype html><meta name="viewport" content="width=device-width"><title>Error</title>` +
      `<body style="font-family:system-ui;padding:2rem"><h1>${status === 404 ? "Not found" : "Something went wrong"}</h1></body>`);
  }
}
