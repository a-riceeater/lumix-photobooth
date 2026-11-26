import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { randomBytes } from "node:crypto";
import sharp, { type Metadata } from "sharp";
import type { Ctx } from "./context.js";
import { loadDesign, type Design } from "./designs.js";
import { badRequest, notFound } from "./errors.js";
import { DESIGN_ID_RE, isDesignId } from "./ids.js";
import { log } from "./log.js";
import { previewScale, renderDesign } from "./render.js";
import { samplePhoto } from "./samples.js";
import { designJson, normalizeParams, type SingleColumnParams } from "./themeBuilder.js";

/** Uploaded images arrive as base64 (data URLs allowed) inside the admin JSON API. */
export interface ThemeAssets {
  background?: string | null;
  foreground?: string | null;
  /** Drop an existing image when editing. */
  removeBackground?: boolean;
  removeForeground?: boolean;
}

const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const MAX_PIXELS = 60_000_000;

function decodeImage(b64: string, field: string): Buffer {
  const data = b64.replace(/^data:[^;,]+;base64,/, "");
  if (!/^[A-Za-z0-9+/=\s]+$/.test(data)) throw badRequest(`${field}: not a valid image upload`);
  const buf = Buffer.from(data, "base64");
  if (buf.length === 0) throw badRequest(`${field}: empty file`);
  if (buf.length > MAX_IMAGE_BYTES) throw badRequest(`${field}: image is larger than 25 MB`);
  return buf;
}

/** Validates an upload and fits it to the canvas (cover = no distortion). */
async function fitToCanvas(buf: Buffer, w: number, h: number, field: string): Promise<Buffer> {
  let meta: Metadata;
  try {
    meta = await sharp(buf, { limitInputPixels: MAX_PIXELS }).metadata();
  } catch {
    throw badRequest(`${field}: unsupported image (use PNG, JPEG or WebP)`);
  }
  if (!meta.format || !["png", "jpeg", "webp"].includes(meta.format)) throw badRequest(`${field}: use PNG, JPEG or WebP`);
  return sharp(buf, { limitInputPixels: MAX_PIXELS }).rotate().resize(w, h, { fit: "cover", position: "centre" }).png().toBuffer();
}

export class ThemeService {
  constructor(private readonly ctx: Ctx) {}

  private get dir(): string {
    return this.ctx.designs.dir;
  }

  list() {
    return {
      themes: this.ctx.designs.list().map((d) => ({
        id: d.id,
        name: d.name,
        description: d.description,
        photoCount: d.photoCount,
        width: d.width,
        height: d.height,
        enabled: d.enabled,
        editable: Boolean(d.builder),
        builder: d.builder,
        hasBackground: Boolean(d.background),
        hasForeground: Boolean(d.foreground),
        previewUrl: `/api/designs/${d.id}/preview`,
      })),
      problems: this.ctx.designs.getProblems(),
    };
  }

  /** Writes a complete design folder (assets + design.json) into `target`. */
  private async writeFolder(target: string, id: string, version: number, p: SingleColumnParams, assets: ThemeAssets,
                            existing: Design | undefined, enabled: boolean): Promise<void> {
    await fsp.mkdir(target, { recursive: true });
    // Keep the uploaded originals ("*-source.png") so a canvas change re-crops cleanly.
    const source = async (kind: "background" | "foreground"): Promise<Buffer | null> => {
      const upload = assets[kind];
      if (upload) return decodeImage(upload, kind);
      if (assets[kind === "background" ? "removeBackground" : "removeForeground"]) return null;
      if (!existing) return null;
      for (const name of [`${kind}-source.png`, `${kind}.png`]) {
        const p2 = path.join(existing.dir, name);
        if (fs.existsSync(p2)) return fsp.readFile(p2);
      }
      return null;
    };
    const flags = { background: false, foreground: false };
    for (const kind of ["background", "foreground"] as const) {
      const src = await source(kind);
      if (!src) continue;
      const fitted = await fitToCanvas(src, p.width, p.height, kind);
      await fsp.writeFile(path.join(target, `${kind}.png`), fitted);
      await fsp.writeFile(path.join(target, `${kind}-source.png`), await sharp(src, { limitInputPixels: MAX_PIXELS }).rotate().png().toBuffer());
      flags[kind] = true;
    }
    const json = designJson(id, version, p, flags, enabled);
    await fsp.writeFile(path.join(target, "design.json"), JSON.stringify({ ...json, preview: null }, null, 2) + "\n");
    const { design, errors } = loadDesign(target);
    if (!design) throw badRequest(`Theme is not valid: ${errors.join("; ")}`);
    const preview = await renderDesign(design, await sampleInputs(design), { scale: previewScale(design, 600), eventName: "Event Name" });
    await sharp(preview).png({ compressionLevel: 9, palette: true, quality: 90 }).toFile(path.join(target, "preview.png"));
    await fsp.writeFile(path.join(target, "design.json"), JSON.stringify(json, null, 2) + "\n");
  }

  /** Renders a preview of unsaved builder settings (nothing is written to DESIGNS_DIR). */
  async preview(paramsRaw: unknown, assets: ThemeAssets, editingId?: unknown): Promise<Buffer> {
    const p = normalizeParams(paramsRaw);
    const existing = editingId ? this.requireTheme(editingId) : undefined;
    const tmp = path.join(this.ctx.cfg.dataDir, "tmp", `theme-${randomBytes(6).toString("hex")}`);
    try {
      // Folder name must equal the design id for validation.
      const target = path.join(tmp, "preview-theme");
      await this.writeFolder(target, "preview-theme", 1, p, assets, existing, true);
      const { design } = loadDesign(target);
      return await renderDesign(design!, await sampleInputs(design!), { scale: previewScale(design!, 1000), eventName: "Event Name" });
    } finally {
      await fsp.rm(tmp, { recursive: true, force: true });
    }
  }

  /** Creates a theme, or updates one made with the builder. Returns its id. */
  async save(body: { id?: unknown; params?: unknown } & ThemeAssets): Promise<string> {
    const p = normalizeParams(body.params);
    const existing = body.id ? this.requireTheme(body.id) : undefined;
    if (existing && !existing.builder) throw badRequest("Only themes made in this page can be edited here");
    const id = existing?.id ?? this.newId(p.name);
    const version = (existing?.version ?? 0) + 1;
    const staging = path.join(this.dir, `.staging-${id}-${randomBytes(4).toString("hex")}`);
    const final = path.join(this.dir, id);
    try {
      await this.writeFolder(staging, id, version, p, body, existing, existing?.enabled ?? true);
      if (existing) await this.toTrash(existing.id);
      await fsp.rename(staging, final);
    } catch (e) {
      await fsp.rm(staging, { recursive: true, force: true });
      throw e;
    }
    this.ctx.designs.reload();
    log.info(existing ? "theme updated" : "theme created", { theme: id, version });
    return id;
  }

  async setEnabled(idRaw: unknown, enabled: boolean): Promise<void> {
    const d = this.requireTheme(idRaw);
    const file = path.join(d.dir, "design.json");
    const json = JSON.parse(await fsp.readFile(file, "utf8"));
    if (enabled) delete json.enabled;
    else json.enabled = false;
    const tmp = `${file}.tmp-${randomBytes(4).toString("hex")}`;
    await fsp.writeFile(tmp, JSON.stringify(json, null, 2) + "\n");
    await fsp.rename(tmp, file);
    this.ctx.designs.reload();
    log.info(enabled ? "theme shown" : "theme hidden", { theme: d.id });
  }

  /** Moves the folder to DESIGNS_DIR/_trash (ignored by the registry, recoverable by hand). */
  async remove(idRaw: unknown): Promise<void> {
    const d = this.requireTheme(idRaw);
    await this.toTrash(d.id);
    this.ctx.designs.reload();
    log.info("theme moved to trash", { theme: d.id });
  }

  private async toTrash(id: string): Promise<void> {
    const trash = path.join(this.dir, "_trash");
    await fsp.mkdir(trash, { recursive: true });
    await fsp.rename(path.join(this.dir, id), path.join(trash, `${id}-${new Date().toISOString().replace(/[:.]/g, "-")}`));
  }

  private requireTheme(idRaw: unknown): Design {
    if (!isDesignId(idRaw)) throw notFound("Theme not found");
    const d = this.ctx.designs.get(idRaw);
    if (!d) throw notFound("Theme not found");
    return d;
  }

  private newId(name: string): string {
    const base = (name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 50)) || "theme";
    for (let i = 1; i < 1000; i++) {
      const id = i === 1 ? base : `${base}-${i}`;
      if (DESIGN_ID_RE.test(id) && !fs.existsSync(path.join(this.dir, id))) return id;
    }
    throw badRequest("Could not pick a theme id; choose another name");
  }
}

async function sampleInputs(d: Design): Promise<Buffer[]> {
  return Promise.all(Array.from({ length: d.photoCount }, (_, i) => samplePhoto(i, 1500, 1000)));
}
