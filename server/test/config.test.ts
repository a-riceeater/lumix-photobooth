import path from "node:path";
import { describe, expect, it } from "vitest";
import { ConfigError, loadConfig } from "../src/config.js";

const base = { DEVICE_API_KEY: "k".repeat(20), ADMIN_PASSWORD: "p".repeat(10) };

describe("configuration", () => {
  it("applies defaults and resolves paths", () => {
    const c = loadConfig(base, "/srv/booth/server");
    expect(c.port).toBe(8080);
    expect(c.publicBaseUrl).toBe("http://localhost:8080");
    expect(c.dataDir).toBe(path.resolve("/srv/booth/server/data"));
    expect(c.photosDir).toBe(path.resolve("/srv/booth/server/data/events"));
    expect(c.designsDir).toBe(path.resolve("/srv/booth/designs"));
    expect(c.smtp).toBeNull();
    expect(c.publicEventGalleryDefault).toBe(false);
  });

  it("supports a separate photo storage location", () => {
    const c = loadConfig({ ...base, PHOTOS_DIR: "/mnt/photos" }, "/srv");
    expect(c.photosDir).toBe(path.resolve("/mnt/photos"));
  });

  it("lists every problem at once", () => {
    try {
      loadConfig({ PORT: "abc", PUBLIC_BASE_URL: "ftp://x", SMTP_HOST: "smtp.x", MAX_UPLOAD_MB: "0" });
      throw new Error("should fail");
    } catch (e) {
      expect(e).toBeInstanceOf(ConfigError);
      const m = (e as Error).message;
      for (const s of ["PORT", "PUBLIC_BASE_URL", "DEVICE_API_KEY", "ADMIN_PASSWORD", "SMTP_FROM_EMAIL", "MAX_UPLOAD_MB"]) expect(m).toContain(s);
    }
  });

  it("strips the trailing slash from the public URL", () => {
    expect(loadConfig({ ...base, PUBLIC_BASE_URL: "https://photos.example.com/" }).publicBaseUrl).toBe("https://photos.example.com");
  });
});
