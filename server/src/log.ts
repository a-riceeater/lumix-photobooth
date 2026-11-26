/**
 * Minimal leveled logger. Never pass credentials or guest email addresses to
 * it; `redact` exists for values that might contain them.
 */
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 } as const;
type Level = keyof typeof LEVELS;

let threshold: number = LEVELS.info;
let silent = false;

export function setLogLevel(level: Level): void {
  threshold = LEVELS[level];
}

/** Used by tests to keep output quiet. */
export function setLogSilent(value: boolean): void {
  silent = value;
}

function write(level: Level, msg: string, fields?: Record<string, unknown>): void {
  if (silent || LEVELS[level] < threshold) return;
  const line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} ${msg}` +
    (fields && Object.keys(fields).length ? " " + JSON.stringify(fields) : "");
  (level === "error" || level === "warn" ? process.stderr : process.stdout).write(line + "\n");
}

export const log = {
  debug: (m: string, f?: Record<string, unknown>) => write("debug", m, f),
  info: (m: string, f?: Record<string, unknown>) => write("info", m, f),
  warn: (m: string, f?: Record<string, unknown>) => write("warn", m, f),
  error: (m: string, f?: Record<string, unknown>) => write("error", m, f),
};

/** "jane.doe@example.com" -> "j***@example.com" (for admin views only). */
export function maskEmail(address: string): string {
  const at = address.lastIndexOf("@");
  if (at < 1) return "***";
  return `${address[0]}***${address.slice(at)}`;
}
