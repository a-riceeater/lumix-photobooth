/**
 * Development seed: creates a sample event with several complete sessions of
 * synthetic photos, so the gallery can be tried without a camera or the app.
 *
 *   npm run seed -- [--event sample-event] [--name "Sample Event"] [--sessions 5] [--photos 3] [--public]
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AdminOps } from "../adminOps.js";
import { createContext } from "../app.js";
import { loadConfigFromEnvFile } from "../config.js";
import { newSessionId, sha256Hex } from "../ids.js";
import { setLogSilent } from "../log.js";
import { samplePhoto } from "../samples.js";

const SERVER_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

function arg(name: string, def: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[i + 1] : def;
}

async function main(): Promise<void> {
  setLogSilent(true);
  const cfg = loadConfigFromEnvFile(SERVER_DIR);
  const ctx = createContext(cfg, { mailTransport: null });
  const eventId = arg("event", "sample-event");
  const eventName = arg("name", "Sample Event");
  const count = Number(arg("sessions", "5"));
  const photos = Number(arg("photos", "3"));

  ctx.sessions.ensureEvent(eventId, eventName);
  if (process.argv.includes("--public")) new AdminOps(ctx).updateEvent(eventId, { galleryMode: "public" });

  console.log(`Seeding ${count} sessions × ${photos} photos into event "${eventId}"…`);
  for (let s = 0; s < count; s++) {
    const id = newSessionId();
    ctx.sessions.createSession({
      id,
      eventId,
      eventName,
      photoCount: photos,
      capturedAt: new Date(Date.now() - (count - s) * 7 * 60_000).toISOString(),
      deviceName: "seed",
    });
    const hashes: string[] = [];
    for (let i = 0; i < photos; i++) {
      const jpeg = await samplePhoto(s * photos + i, 3000, 2000, `${s + 1}.${i + 1}`);
      hashes.push(sha256Hex(jpeg));
      await ctx.sessions.addPhoto(id, i, jpeg);
    }
    ctx.sessions.complete(id, hashes);
    console.log(`  ${ctx.sessions.galleryUrl(id)}`);
  }
  const ev = ctx.sessions.getEvent(eventId)!;
  console.log(`\nEvent gallery (${ev.gallery_mode}): ${cfg.publicBaseUrl}/gallery/${eventId}`);
  if (ev.gallery_mode === "disabled") console.log("Enable it with --public, the admin page, or: npm run cli -- gallery sample-event public");
  ctx.db.close();
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
