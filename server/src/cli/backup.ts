/**
 * Online backup (safe while the server runs):
 *   npm run backup -- /path/to/backups            (dev)
 *   node dist/cli/backup.js /path/to/backups      (production)
 * Creates <dest>/photobooth-<timestamp>/ with a consistent SQLite copy
 * (SQLite backup API) and the photo folders. Originals are never modified,
 * so copying them while uploads continue is safe; the database copy is taken
 * first, so every photo it references is included.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { loadConfigFromEnvFile } from "../config.js";

const SERVER_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

async function main(): Promise<void> {
  const destRoot = process.argv[2];
  if (!destRoot) throw new Error("usage: npm run backup -- <destination folder>");
  const cfg = loadConfigFromEnvFile(SERVER_DIR);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dest = path.resolve(destRoot, `photobooth-${stamp}`);
  fs.mkdirSync(dest, { recursive: true });

  const db = new Database(path.join(cfg.dataDir, "photobooth.sqlite"), { readonly: true, fileMustExist: true });
  await db.backup(path.join(dest, "photobooth.sqlite"));
  db.close();
  console.log(`database → ${path.join(dest, "photobooth.sqlite")}`);

  fs.cpSync(cfg.photosDir, path.join(dest, "photos"), {
    recursive: true,
    filter: (src) => path.basename(src) !== ".tmp",
  });
  console.log(`photos   → ${path.join(dest, "photos")}`);
  console.log("Restore: stop the server, copy photobooth.sqlite into DATA_DIR and photos/ into PHOTOS_DIR, start the server.");
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
