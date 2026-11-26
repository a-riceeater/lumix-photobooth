import fs from "node:fs";
import path from "node:path";
import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { layoutSingleColumn, layoutWarnings, normalizeParams, SINGLE_COLUMN_DEFAULTS } from "../src/themeBuilder.js";
import { ADMIN_PASSWORD, REPO_DESIGNS, startServer, tempDir, uploadSession } from "./helpers.js";

const basic = "Basic " + Buffer.from(`admin:${ADMIN_PASSWORD}`).toString("base64");

function serverWithScratchDesigns() {
  const designs = tempDir("pb-themes-");
  fs.cpSync(path.join(REPO_DESIGNS, "classic-white"), path.join(designs, "classic-white"), { recursive: true });
  return { s: startServer(undefined, { DESIGNS_DIR: designs }), designs };
}

async function pngDataUrl(w: number, h: number, color: string, alpha = 1): Promise<string> {
  const buf = await sharp({ create: { width: w, height: h, channels: 4, background: { ...hex(color), alpha } } }).png().toBuffer();
  return "data:image/png;base64," + buf.toString("base64");
}
const hex = (c: string) => ({ r: parseInt(c.slice(1, 3), 16), g: parseInt(c.slice(3, 5), 16), b: parseInt(c.slice(5, 7), 16) });

describe("single-column layout", () => {
  it("stacks 3:2 photos centred in the column above the text area", () => {
    const { photos, texts } = layoutSingleColumn({ ...SINGLE_COLUMN_DEFAULTS, photoCount: 4 });
    expect(photos).toHaveLength(4);
    for (const p of photos) {
      expect(p.width / p.height).toBeCloseTo(1.5, 1);
      expect(p.x + p.width / 2).toBeCloseTo(600, 0);
      expect(p.y + p.height).toBeLessThanOrEqual(3600 - 600 - 60 + 1); // above the text area
    }
    for (let i = 1; i < 4; i++) expect(photos[i].y - (photos[i - 1].y + photos[i - 1].height)).toBe(60);
    expect(texts.map((t) => t.text)).toEqual(["{eventName}", "{date}"]);
    expect(texts.every((t) => (t.y as number) > 3000)).toBe(true);
  });

  it("fills the column when photoShape is fill, and puts text on top when asked", () => {
    const { photos, texts } = layoutSingleColumn({ ...SINGLE_COLUMN_DEFAULTS, photoShape: "fill", textPosition: "top" });
    expect(photos[0].width).toBe(1080);
    expect(photos[0].y).toBeGreaterThanOrEqual(600);
    expect(texts.every((t) => (t.y as number) < 600)).toBe(true);
  });

  it("places photos at a fixed top margin instead of centring them", () => {
    const centred = layoutSingleColumn(normalizeParams({ name: "x" })).photos;
    const top = layoutSingleColumn(normalizeParams({ name: "x", topMargin: 300 })).photos;
    expect(top[0].y).toBe(300);
    expect(centred[0].y).not.toBe(300);
    // Moving the stack never resizes the photos, in either shape.
    for (const photoShape of ["keep", "fill"]) {
      const a = layoutSingleColumn(normalizeParams({ name: "x", photoShape })).photos;
      const b = layoutSingleColumn(normalizeParams({ name: "x", photoShape, topMargin: 40 })).photos;
      const c = layoutSingleColumn(normalizeParams({ name: "x", photoShape, topMargin: 500 })).photos;
      expect(b.map((p) => [p.width, p.height])).toEqual(a.map((p) => [p.width, p.height]));
      expect(c.map((p) => [p.width, p.height])).toEqual(a.map((p) => [p.width, p.height]));
      expect(b[0].y).toBe(40);
      expect(c[0].y).toBe(500);
    }
    expect(normalizeParams({ name: "x", topMargin: "" }).topMargin).toBeNull();
    expect(() => normalizeParams({ name: "x", topMargin: -5 })).toThrow(/topMargin/);
  });

  it("warns instead of shrinking when the top margin pushes photos too far", () => {
    expect(layoutWarnings(normalizeParams({ name: "x" }))).toEqual([]);
    expect(layoutWarnings(normalizeParams({ name: "x", topMargin: 900 })).join()).toMatch(/text area/);
    expect(layoutWarnings(normalizeParams({ name: "x", topMargin: 2000 })).join()).toMatch(/past the bottom/);
  });

  it("drops the text block entirely when text is off", () => {
    const { photos, texts } = layoutSingleColumn(normalizeParams({ name: "x", textPosition: "none", photoShape: "fill" }));
    expect(texts).toEqual([]);
    expect(photos[2].y + photos[2].height).toBe(3600 - 60); // photos reach the bottom margin
  });

  it("rejects bad input with readable messages", () => {
    expect(() => normalizeParams({ name: "" })).toThrow(/name/);
    expect(() => normalizeParams({ name: "x", photoCount: 20 })).toThrow(/photoCount/);
    expect(() => normalizeParams({ name: "x", textColor: "red" })).toThrow(/colour/);
    expect(() => normalizeParams({ name: "x", fontFamily: "<script>" })).toThrow(/fontFamily/);
    expect(() => layoutSingleColumn(normalizeParams({ name: "x", height: 400, photoCount: 8, gap: 200 }))).toThrow(/don't fit/);
  });
});

describe("admin theme API", () => {
  it("requires admin auth", async () => {
    const { s } = serverWithScratchDesigns();
    await s.agent.get("/api/admin/themes").expect(401);
    await s.agent.post("/api/admin/themes").send({ params: { name: "x" } }).expect(401);
  });

  it("previews without writing anything", async () => {
    const { s, designs } = serverWithScratchDesigns();
    const before = fs.readdirSync(designs);
    const res = await s.agent.post("/api/admin/themes/preview").set("Authorization", basic)
      .send({ params: { name: "Try", photoCount: 2 }, background: await pngDataUrl(300, 900, "#ff0000") })
      .buffer(true).parse((r, cb) => { const c: Buffer[] = []; r.on("data", (d: Buffer) => c.push(d)); r.on("end", () => cb(null, Buffer.concat(c))); })
      .expect(200);
    expect(res.headers["content-type"]).toBe("image/jpeg");
    expect((await sharp(res.body).metadata()).height).toBeGreaterThan(500);
    expect(fs.readdirSync(designs)).toEqual(before);
  });

  it("creates, edits, hides and deletes a theme used by galleries", async () => {
    const { s, designs } = serverWithScratchDesigns();
    const created = await s.agent.post("/api/admin/themes").set("Authorization", basic)
      .send({ params: { name: "Gold Gala", photoCount: 3, backgroundColor: "#222222", textColor: "#ffd700" },
              background: await pngDataUrl(600, 600, "#00ff00"),
              foreground: await pngDataUrl(100, 100, "#0000ff", 0.3) });
    expect(created.body).toEqual({ id: "gold-gala" });
    expect(created.status).toBe(201);
    const id = created.body.id;
    expect(id).toBe("gold-gala");
    const dir = path.join(designs, id);
    for (const f of ["design.json", "background.png", "foreground.png", "preview.png", "background-source.png"]) {
      expect(fs.existsSync(path.join(dir, f))).toBe(true);
    }
    const bg = await sharp(path.join(dir, "background.png")).metadata();
    expect([bg.width, bg.height]).toEqual([1200, 3600]); // fitted to the canvas, not stretched later

    // A completed 3-photo session now offers it and renders a full strip with it.
    const { id: session } = await uploadSession(s);
    const view = await s.agent.get(`/api/sessions/${session}`).expect(200);
    expect(view.body.designs.map((d: { id: string }) => d.id)).toContain(id);
    await s.agent.get(`/api/sessions/${session}/strip?design=${id}`).expect(200);

    // Edit: a new name and 4 photos; the image is kept from the previous version.
    await s.agent.post("/api/admin/themes").set("Authorization", basic)
      .send({ id, params: { name: "Gold Gala", photoCount: 4 } }).expect(200);
    const json = JSON.parse(fs.readFileSync(path.join(dir, "design.json"), "utf8"));
    expect(json.version).toBe(2);
    expect(json.photoCount).toBe(4);
    expect(json.background).toBe("background.png");
    expect(fs.readdirSync(path.join(designs, "_trash")).some((f) => f.startsWith(`${id}-`))).toBe(true);

    // Hide → gone from galleries and the public list, still in the admin list.
    await s.agent.patch(`/api/admin/themes/${id}`).set("Authorization", basic).send({ enabled: false }).expect(200);
    const pub = await s.agent.get("/api/designs").expect(200);
    expect(pub.body.designs.map((d: { id: string }) => d.id)).not.toContain(id);
    const admin = await s.agent.get("/api/admin/themes").set("Authorization", basic).expect(200);
    expect(admin.body.themes.find((t: { id: string }) => t.id === id).enabled).toBe(false);

    // Built-in designs can't be edited with the builder, only hidden/deleted.
    await s.agent.post("/api/admin/themes").set("Authorization", basic)
      .send({ id: "classic-white", params: { name: "x" } }).expect(400);

    await s.agent.delete(`/api/admin/themes/${id}`).set("Authorization", basic).send({}).expect(200);
    expect(fs.existsSync(dir)).toBe(false);
    await s.agent.delete("/api/admin/themes/../classic-white").set("Authorization", basic).send({}).expect(404);
  });

  it("saves a copy as a new theme without touching the original", async () => {
    const { s, designs } = serverWithScratchDesigns();
    const first = await s.agent.post("/api/admin/themes").set("Authorization", basic)
      .send({ params: { name: "Banquet", photoCount: 4 }, background: await pngDataUrl(300, 900, "#ff0000") }).expect(201);
    const before = fs.readFileSync(path.join(designs, first.body.id, "design.json"), "utf8");
    // "Save as new theme" / Duplicate: copyFrom, no id, a different layout, no new upload.
    const copy = await s.agent.post("/api/admin/themes").set("Authorization", basic)
      .send({ copyFrom: first.body.id, params: { name: "Banquet", photoCount: 4, topMargin: 200 } }).expect(201);
    expect(copy.body.id).toBe("banquet-2");
    expect(fs.readFileSync(path.join(designs, "banquet", "design.json"), "utf8")).toBe(before);
    expect(JSON.parse(fs.readFileSync(path.join(designs, "banquet-2", "design.json"), "utf8")).background).toBe("background.png");
    const px = async (id: string) => [...(await sharp(path.join(designs, id, "background.png")).extract({ left: 5, top: 5, width: 1, height: 1 }).raw().toBuffer())].slice(0, 3);
    expect(await px("banquet-2")).toEqual(await px("banquet"));
    expect(fs.existsSync(path.join(designs, "_trash"))).toBe(false);
  });

  it("rejects non-image uploads", async () => {
    const { s } = serverWithScratchDesigns();
    const r = await s.agent.post("/api/admin/themes").set("Authorization", basic)
      .send({ params: { name: "Bad" }, background: "data:image/png;base64," + Buffer.from("not an image").toString("base64") })
      .expect(400);
    expect(r.body.message).toMatch(/background/);
  });
});
