import path from "node:path";
import { fileURLToPath } from "node:url";
import { createApp, createContext } from "./app.js";
import { ConfigError, loadConfigFromEnvFile } from "./config.js";
import { log, setLogLevel } from "./log.js";

const SERVER_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function main(): void {
  let cfg;
  try {
    cfg = loadConfigFromEnvFile(SERVER_DIR);
  } catch (e) {
    if (e instanceof ConfigError) {
      console.error(e.message);
      console.error("\nSee server/.env.example. `npm run init-env` creates a .env with random secrets.");
      process.exit(1);
    }
    throw e;
  }
  setLogLevel(cfg.logLevel);
  const ctx = createContext(cfg);
  const app = createApp(ctx);
  void ctx.storage.cleanTemp();
  ctx.email.start();

  const server = app.listen(cfg.port, cfg.host, () => {
    log.info(`photo booth server listening on http://${cfg.host}:${cfg.port}`, {
      publicBaseUrl: cfg.publicBaseUrl,
      dataDir: cfg.dataDir,
      photosDir: cfg.photosDir,
      designs: ctx.designs.list().map((d) => d.id),
      email: ctx.email.enabled ? "enabled" : "disabled (SMTP_HOST not set)",
    });
  });
  // Large uploads over slow event Wi-Fi need generous timeouts.
  server.requestTimeout = 10 * 60_000;
  server.headersTimeout = 60_000;

  process.on("SIGHUP", () => {
    const { loaded } = ctx.designs.reload();
    log.info("designs reloaded", { loaded });
  });
  const shutdown = (signal: string) => {
    log.info(`${signal} received, shutting down`);
    ctx.email.stop();
    server.close(() => {
      ctx.db.close();
      process.exit(0);
    });
    setTimeout(() => process.exit(0), 10_000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main();
