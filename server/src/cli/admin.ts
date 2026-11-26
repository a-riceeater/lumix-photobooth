/**
 * Administrative CLI (works while the server is running; SQLite is in WAL mode).
 *
 *   npm run cli -- events
 *   npm run cli -- create-event <id> [name...]
 *   npm run cli -- rename-event <id> <name...>
 *   npm run cli -- gallery <eventId> <disabled|public|password> [password]
 *   npm run cli -- delete-event <eventId> --yes
 *   npm run cli -- sessions <eventId> [complete|uploading]
 *   npm run cli -- delete-session <sessionId>
 *   npm run cli -- retry-emails
 *   npm run cli -- designs
 *
 * In production (compiled): node dist/cli/admin.js <command> ...
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AdminOps } from "../adminOps.js";
import { createContext } from "../app.js";
import { loadConfigFromEnvFile } from "../config.js";
import { setLogSilent } from "../log.js";

const SERVER_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

async function main(): Promise<number> {
  setLogSilent(true);
  const [cmd, ...args] = process.argv.slice(2);
  const ctx = createContext(loadConfigFromEnvFile(SERVER_DIR), { mailTransport: null });
  const ops = new AdminOps(ctx);
  try {
    switch (cmd) {
      case "events": {
        const { events } = ops.overview();
        if (!events.length) console.log("No events.");
        for (const e of events) {
          console.log(`${e.id}  "${e.name}"  gallery=${e.galleryMode}${e.galleryPasswordSet ? " (password set)" : ""}`);
          console.log(`    ${e.complete} complete, ${e.uploading} uploading, ${e.photos} photos, ${(e.bytes / 1048576).toFixed(1)} MB; ` +
            `emails ${e.emails.sent} sent / ${e.emails.pending} pending / ${e.emails.failed} failed`);
        }
        return 0;
      }
      case "create-event":
        ops.createEvent(args[0], args.slice(1).join(" ") || undefined);
        console.log(`Created ${args[0]}.`);
        return 0;
      case "rename-event":
        ops.updateEvent(args[0], { name: args.slice(1).join(" ") });
        console.log("Renamed.");
        return 0;
      case "gallery": {
        const [id, mode, password] = args;
        const patch: Record<string, unknown> = { galleryMode: mode };
        if (password) patch.galleryPassword = password;
        ops.updateEvent(id, patch);
        console.log(`Event gallery for ${id} is now ${mode}: ${ctx.cfg.publicBaseUrl}/gallery/${id}`);
        return 0;
      }
      case "delete-event":
        if (!args.includes("--yes")) {
          console.error("This deletes every session and photo of the event. Re-run with --yes.");
          return 1;
        }
        await ops.deleteEvent(args[0]);
        console.log(`Deleted ${args[0]}.`);
        return 0;
      case "sessions": {
        const rows = ops.sessions(args[0], { status: args[1], limit: 200 });
        for (const s of rows) {
          const emails = s.emails.map((m) => `${(m as { masked: string }).masked}:${(m as { status: string }).status}`).join(" ");
          console.log(`${s.id}  ${s.status.padEnd(9)} ${s.uploaded}/${s.photoCount}  ${s.capturedAt ?? s.createdAt}  ${emails}`);
        }
        console.log(`${rows.length} session(s)`);
        return 0;
      }
      case "delete-session":
        await ops.deleteSession(args[0]);
        console.log("Deleted.");
        return 0;
      case "retry-emails":
        console.log(`${ops.retryEmails()} email(s) queued again (the running server sends them).`);
        return 0;
      case "designs": {
        for (const d of ctx.designs.list()) console.log(`${d.id}  ${d.photoCount} photos  ${d.width}x${d.height}  "${d.name}"`);
        for (const p of ctx.designs.getProblems()) {
          for (const e of p.errors) console.log(`  ✘ ${p.id}: ${e}`);
          for (const w of p.warnings) console.log(`  ! ${p.id}: ${w}`);
        }
        return 0;
      }
      default:
        console.log("Commands: events, create-event, rename-event, gallery, delete-event, sessions, delete-session, retry-emails, designs");
        console.log("See the header of src/cli/admin.ts for usage.");
        return cmd ? 1 : 0;
    }
  } finally {
    ctx.db.close();
  }
}

main().then((code) => process.exit(code), (e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
