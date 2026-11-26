// Creates server/.env from .env.example with freshly generated secrets.
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

if (existsSync(".env")) {
  console.error(".env already exists; not overwriting it.");
  process.exit(1);
}
const secret = () => randomBytes(24).toString("base64url");
const text = readFileSync(".env.example", "utf8")
  .replace(/^DEVICE_API_KEY=$/m, `DEVICE_API_KEY=${secret()}`)
  .replace(/^ADMIN_PASSWORD=$/m, `ADMIN_PASSWORD=${secret()}`);
writeFileSync(".env", text, { mode: 0o600 });
console.log("Wrote .env with new DEVICE_API_KEY and ADMIN_PASSWORD.");
console.log("Show them with: grep -E '^(DEVICE_API_KEY|ADMIN_PASSWORD)=' .env");
