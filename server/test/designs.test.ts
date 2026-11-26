import fs from "node:fs";
import path from "node:path";
import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { DesignRegistry, loadDesign } from "../src/designs.js";
import { fillPlaceholders, renderDesign } from "../src/render.js";
import { photos, REPO_DESIGNS, tempDir } from "./helpers.js";

const PNG_1x1 = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000" +
  "1f15c4890000000d49444154789c6360f8cf000000030101005f5ef3f10000000049454e44ae426082", "hex");

function makeDesign(json: Record<string, unknown>, files: Record<string, Buffer> = {}): string {
  const root = tempDir("pb-design-");
  const dir = path.join(root, "test-design");
  fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir, "design.json"), JSON.stringify(json));
  for (const [name, data] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), data);
  return dir;
}

const valid = {
  id: "test-design", name: "Test", version: 1, width: 600, height: 1800, photoCount: 2,
  background: "background.png", foreground: "foreground.png",
  photos: [
    { index: 0, x: 30, y: 30, width: 540, height: 360, fit: "cover" },
    { index: 1, x: 30, y: 420, width: 540, height: 360, fit: "contain", radius: 20, rotation: 5 },
  ],
  texts: [{ text: "{eventName}", x: 0, y: 1700, width: 600, align: "center", fontSize: 40, color: "#000000" }],
};

describe("design validation", () => {
  it("accepts every bundled example design", () => {
    const reg = new DesignRegistry(REPO_DESIGNS);
    expect(reg.list().length).toBeGreaterThanOrEqual(5);
    expect(reg.getProblems().flatMap((p) => p.errors)).toEqual([]);
    expect(reg.compatible(3).every((d) => d.photoCount === 3)).toBe(true);
    expect(reg.compatible(4).map((d) => d.id)).toEqual(["grid-four"]);
  });

  it("accepts a valid design", () => {
    const dir = makeDesign(valid, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 });
    const { design, errors } = loadDesign(dir);
    expect(errors).toEqual([]);
    expect(design?.fingerprint).toMatch(/^[0-9a-f]{12}$/);
  });

  it("reports helpful errors", () => {
    const cases: [Record<string, unknown>, Record<string, Buffer>, RegExp][] = [
      [{ ...valid, id: "other-name" }, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 }, /must match the folder name/],
      [{ ...valid }, { "foreground.png": PNG_1x1 }, /background: file "background.png" not found/],
      [{ ...valid }, { "background.png": Buffer.from("not a png"), "foreground.png": PNG_1x1 }, /is not a PNG file/],
      [{ ...valid, background: "../../etc/passwd" }, { "foreground.png": PNG_1x1 }, /must be a PNG file name/],
      [{ ...valid, photoCount: 3 }, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 }, /no slot shows photo index 2/],
      [{ ...valid, photos: [{ ...valid.photos[0], index: 5 }, valid.photos[1]] }, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 }, /out of range/],
      [{ ...valid, width: "wide" }, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 }, /width must be a number/],
      [{ ...valid, photos: [{ ...valid.photos[0], fit: "stretch" }, valid.photos[1]] }, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 }, /fit must be "cover" or "contain"/],
      [{ ...valid, photos: [{ ...valid.photos[0], x: 5000 }, valid.photos[1]] }, { "background.png": PNG_1x1, "foreground.png": PNG_1x1 }, /completely outside/],
    ];
    for (const [json, files, re] of cases) {
      const { design, errors } = loadDesign(makeDesign(json, files));
      expect(design).toBeNull();
      expect(errors.join("\n")).toMatch(re);
    }
    const broken = makeDesign({}, {});
    fs.writeFileSync(path.join(broken, "design.json"), "{ not json");
    expect(loadDesign(broken).errors[0]).toMatch(/not valid JSON/);
  });

  it("registers a new folder on reload without code changes", () => {
    const root = tempDir("pb-designs-");
    const reg = new DesignRegistry(root, 60_000);
    expect(reg.list()).toHaveLength(0);
    fs.cpSync(path.join(REPO_DESIGNS, "classic-white"), path.join(root, "classic-white"), { recursive: true });
    reg.reload();
    expect(reg.list().map((d) => d.id)).toEqual(["classic-white"]);
  });
});

describe("rendering", () => {
  it("renders at full canvas size with all layers", async () => {
    const red = await sharp({ create: { width: 10, height: 10, channels: 4, background: "#ff0000" } }).png().toBuffer();
    const fg = await sharp({ create: { width: 600, height: 1800, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
      .composite([{ input: await sharp({ create: { width: 600, height: 20, channels: 4, background: "#0000ff" } }).png().toBuffer(), left: 0, top: 0 }])
      .png().toBuffer();
    const dir = makeDesign(valid, { "background.png": red, "foreground.png": fg });
    const design = loadDesign(dir).design!;
    const out = await renderDesign(design, await photos(2), { eventName: "Party" });
    const meta = await sharp(out).metadata();
    expect([meta.width, meta.height, meta.format]).toEqual([600, 1800, "jpeg"]);
    const px = async (x: number, y: number) => {
      const { data } = await sharp(out).extract({ left: x, top: y, width: 1, height: 1 }).raw().toBuffer({ resolveWithObject: true });
      return [...data];
    };
    const [r, g, b] = await px(5, 1000); // background shows through
    expect(r).toBeGreaterThan(200);
    expect(g + b).toBeLessThan(60);
    const [r2, , b2] = await px(300, 5); // foreground on top
    expect(b2).toBeGreaterThan(200);
    expect(r2).toBeLessThan(60);
  });

  it("renders reduced-size previews", async () => {
    const design = loadDesign(path.join(REPO_DESIGNS, "classic-white")).design!;
    const out = await renderDesign(design, await photos(3), { scale: 0.25 });
    const meta = await sharp(out).metadata();
    expect([meta.width, meta.height]).toEqual([300, 900]);
  });

  it("fills text placeholders", () => {
    const t = fillPlaceholders("{eventName} – {date}", { eventName: "Gala", date: new Date("2026-06-01T12:00:00Z") });
    expect(t).toBe("Gala – June 1, 2026");
  });
});
