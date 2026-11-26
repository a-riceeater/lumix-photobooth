import path from "node:path";
import { config as loadDotenv } from "dotenv";

export interface SmtpConfig {
  host: string;
  port: number;
  secure: boolean;
  user: string;
  password: string;
  fromName: string;
  fromEmail: string;
}

export interface AppConfig {
  port: number;
  host: string;
  publicBaseUrl: string;
  trustProxy: number;
  dataDir: string;
  /** Where event/session photo folders live (default DATA_DIR/events). */
  photosDir: string;
  designsDir: string;
  deviceApiKey: string;
  adminPassword: string;
  smtp: SmtpConfig | null;
  emailMaxPerSession: number;
  emailMaxPerHour: number;
  maxUploadBytes: number;
  maxImageDimension: number;
  publicEventGalleryDefault: boolean;
  logLevel: "debug" | "info" | "warn" | "error";
  /** Interval of the background email worker; tests shorten it. */
  emailPollMs: number;
}

export class ConfigError extends Error {}

function int(env: NodeJS.ProcessEnv, key: string, def: number, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === "") return def;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new ConfigError(`${key} must be an integer between ${min} and ${max} (got "${raw}")`);
  }
  return n;
}

function bool(env: NodeJS.ProcessEnv, key: string, def: boolean): boolean {
  const raw = env[key]?.trim().toLowerCase();
  if (!raw) return def;
  if (["1", "true", "yes", "on"].includes(raw)) return true;
  if (["0", "false", "no", "off"].includes(raw)) return false;
  throw new ConfigError(`${key} must be true or false (got "${env[key]}")`);
}

/**
 * Builds and validates the configuration. Relative paths are resolved
 * against `baseDir` (the server folder) so the server can be started from
 * anywhere. Throws ConfigError with every problem listed.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env, baseDir = process.cwd()): AppConfig {
  const errors: string[] = [];
  const attempt = <T>(fn: () => T, fallback: T): T => {
    try {
      return fn();
    } catch (e) {
      errors.push((e as Error).message);
      return fallback;
    }
  };

  const port = attempt(() => int(env, "PORT", 8080, 1, 65535), 8080);
  const publicBaseUrl = (env.PUBLIC_BASE_URL?.trim() || `http://localhost:${port}`).replace(/\/+$/, "");
  try {
    const u = new URL(publicBaseUrl);
    if (!["http:", "https:"].includes(u.protocol)) errors.push("PUBLIC_BASE_URL must start with http:// or https://");
  } catch {
    errors.push(`PUBLIC_BASE_URL is not a valid URL ("${publicBaseUrl}")`);
  }

  const deviceApiKey = env.DEVICE_API_KEY?.trim() ?? "";
  const adminPassword = env.ADMIN_PASSWORD?.trim() ?? "";
  if (deviceApiKey.length < 16) errors.push("DEVICE_API_KEY is required and must be at least 16 characters (run `npm run init-env`)");
  if (adminPassword.length < 8) errors.push("ADMIN_PASSWORD is required and must be at least 8 characters");

  let smtp: SmtpConfig | null = null;
  const smtpHost = env.SMTP_HOST?.trim();
  if (smtpHost) {
    const fromEmail = env.SMTP_FROM_EMAIL?.trim() ?? "";
    if (!fromEmail.includes("@")) errors.push("SMTP_FROM_EMAIL must be set when SMTP_HOST is set");
    smtp = {
      host: smtpHost,
      port: attempt(() => int(env, "SMTP_PORT", 587, 1, 65535), 587),
      secure: attempt(() => bool(env, "SMTP_SECURE", false), false),
      user: env.SMTP_USER?.trim() ?? "",
      password: env.SMTP_PASSWORD ?? "",
      fromName: env.SMTP_FROM_NAME?.trim() || "Photo Booth",
      fromEmail,
    };
  }

  const dataDir = path.resolve(baseDir, env.DATA_DIR?.trim() || "./data");

  const logLevel = (env.LOG_LEVEL?.trim() || "info") as AppConfig["logLevel"];
  if (!["debug", "info", "warn", "error"].includes(logLevel)) errors.push("LOG_LEVEL must be debug, info, warn or error");

  const cfg: AppConfig = {
    port,
    host: env.HOST?.trim() || "0.0.0.0",
    publicBaseUrl,
    trustProxy: attempt(() => int(env, "TRUST_PROXY", 0, 0, 10), 0),
    dataDir,
    photosDir: path.resolve(baseDir, env.PHOTOS_DIR?.trim() || path.join(dataDir, "events")),
    designsDir: path.resolve(baseDir, env.DESIGNS_DIR?.trim() || "../designs"),
    deviceApiKey,
    adminPassword,
    smtp,
    emailMaxPerSession: attempt(() => int(env, "EMAIL_MAX_PER_SESSION", 3, 1, 50), 3),
    emailMaxPerHour: attempt(() => int(env, "EMAIL_MAX_PER_HOUR", 200, 1, 100000), 200),
    maxUploadBytes: attempt(() => int(env, "MAX_UPLOAD_MB", 50, 1, 500), 50) * 1024 * 1024,
    maxImageDimension: attempt(() => int(env, "MAX_IMAGE_DIMENSION", 12000, 100, 50000), 12000),
    publicEventGalleryDefault: attempt(() => bool(env, "PUBLIC_EVENT_GALLERY", false), false),
    logLevel,
    emailPollMs: attempt(() => int(env, "EMAIL_POLL_MS", 5000, 50, 600000), 5000),
  };
  if (errors.length) throw new ConfigError("Invalid configuration:\n  - " + errors.join("\n  - "));
  return cfg;
}

/** Loads server/.env (if present) into process.env, then validates. */
export function loadConfigFromEnvFile(baseDir = process.cwd()): AppConfig {
  loadDotenv({ path: path.join(baseDir, ".env"), quiet: true });
  return loadConfig(process.env, baseDir);
}
