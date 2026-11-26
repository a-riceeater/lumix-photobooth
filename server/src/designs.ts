import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { DESIGN_ID_RE } from "./ids.js";
import { log } from "./log.js";

export type Fit = "cover" | "contain";

export interface PhotoSlot {
  /** 0-based index of the session photo placed in this slot. */
  index: number;
  x: number;
  y: number;
  width: number;
  height: number;
  fit: Fit;
  /** Corner radius in canvas pixels. */
  radius: number;
  /** Clockwise rotation in degrees around the slot centre. */
  rotation: number;
}

export interface TextElement {
  /** Supports {eventName}, {date} and {time} placeholders. */
  text: string;
  x: number;
  y: number;
  /** Box width used for alignment; defaults to the canvas width minus x. */
  width: number;
  fontSize: number;
  fontFamily: string;
  fontWeight: string;
  color: string;
  align: "left" | "center" | "right";
  rotation: number;
}

export interface Design {
  id: string;
  name: string;
  description: string;
  version: number;
  width: number;
  height: number;
  photoCount: number;
  backgroundColor: string;
  background: string | null;
  foreground: string | null;
  preview: string | null;
  photos: PhotoSlot[];
  texts: TextElement[];
  /** Absolute folder path. */
  dir: string;
  /** Changes whenever design.json or any referenced asset changes. */
  fingerprint: string;
}

export interface DesignProblem {
  id: string;
  dir: string;
  errors: string[];
  warnings: string[];
}

const ASSET_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*\.png$/;
const COLOR_RE = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;
const MAX_CANVAS = 12000;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Validation of one design folder. Never throws; problems are returned. */
export function loadDesign(dir: string): { design: Design | null; errors: string[]; warnings: string[] } {
  const errors: string[] = [];
  const warnings: string[] = [];
  const folder = path.basename(dir);
  const jsonPath = path.join(dir, "design.json");
  let raw: string;
  let json: Record<string, unknown>;
  try {
    raw = fs.readFileSync(jsonPath, "utf8");
  } catch {
    return { design: null, errors: [`missing design.json in ${dir}`], warnings };
  }
  try {
    json = JSON.parse(raw);
    if (typeof json !== "object" || json === null || Array.isArray(json)) throw new Error("not an object");
  } catch (e) {
    return { design: null, errors: [`design.json is not valid JSON: ${(e as Error).message}`], warnings };
  }

  const num = (v: unknown, field: string, opts: { min?: number; max?: number; int?: boolean; def?: number } = {}): number => {
    if (v === undefined && opts.def !== undefined) return opts.def;
    if (typeof v !== "number" || !Number.isFinite(v)) {
      errors.push(`${field} must be a number`);
      return opts.def ?? 0;
    }
    if (opts.int && !Number.isInteger(v)) errors.push(`${field} must be a whole number`);
    if (opts.min !== undefined && v < opts.min) errors.push(`${field} must be at least ${opts.min} (got ${v})`);
    if (opts.max !== undefined && v > opts.max) errors.push(`${field} must be at most ${opts.max} (got ${v})`);
    return v;
  };
  const str = (v: unknown, field: string, def?: string): string => {
    if (v === undefined && def !== undefined) return def;
    if (typeof v !== "string" || v.trim() === "") {
      errors.push(`${field} must be a non-empty string`);
      return def ?? "";
    }
    return v;
  };
  const color = (v: unknown, field: string, def: string): string => {
    const c = str(v, field, def);
    if (!COLOR_RE.test(c)) errors.push(`${field} must be a hex color like #ffffff (got "${c}")`);
    return c;
  };
  const asset = (v: unknown, field: string, required: boolean): string | null => {
    if (v === null || v === undefined) {
      if (required) errors.push(`${field} is required`);
      return null;
    }
    if (typeof v !== "string" || !ASSET_RE.test(v)) {
      errors.push(`${field} must be a PNG file name in the design folder, e.g. "background.png" (got ${JSON.stringify(v)})`);
      return null;
    }
    const p = path.join(dir, v);
    if (!fs.existsSync(p)) {
      errors.push(`${field}: file "${v}" not found in ${folder}/`);
      return null;
    }
    const head = Buffer.alloc(8);
    const fd = fs.openSync(p, "r");
    fs.readSync(fd, head, 0, 8, 0);
    fs.closeSync(fd);
    if (!head.equals(PNG_MAGIC)) errors.push(`${field}: "${v}" is not a PNG file`);
    return v;
  };

  const id = str(json.id, "id");
  if (id && !DESIGN_ID_RE.test(id)) errors.push(`id "${id}" may only contain lowercase letters, digits and dashes`);
  if (id && id !== folder) errors.push(`id "${id}" must match the folder name "${folder}"`);
  const width = num(json.width, "width", { min: 100, max: MAX_CANVAS, int: true });
  const height = num(json.height, "height", { min: 100, max: MAX_CANVAS, int: true });
  const photoCount = num(json.photoCount, "photoCount", { min: 1, max: 12, int: true });

  const photos: PhotoSlot[] = [];
  if (!Array.isArray(json.photos) || json.photos.length === 0) {
    errors.push("photos must be a non-empty array of photo slots");
  } else {
    json.photos.forEach((p: Record<string, unknown>, i: number) => {
      const f = `photos[${i}]`;
      if (typeof p !== "object" || p === null) {
        errors.push(`${f} must be an object`);
        return;
      }
      const fit = (p.fit ?? "cover") as Fit;
      if (fit !== "cover" && fit !== "contain") errors.push(`${f}.fit must be "cover" or "contain"`);
      const slot: PhotoSlot = {
        index: num(p.index, `${f}.index`, { min: 0, max: 11, int: true }),
        x: num(p.x, `${f}.x`, { int: true }),
        y: num(p.y, `${f}.y`, { int: true }),
        width: num(p.width, `${f}.width`, { min: 10, max: MAX_CANVAS, int: true }),
        height: num(p.height, `${f}.height`, { min: 10, max: MAX_CANVAS, int: true }),
        fit,
        radius: num(p.radius, `${f}.radius`, { min: 0, def: 0 }),
        rotation: num(p.rotation, `${f}.rotation`, { min: -360, max: 360, def: 0 }),
      };
      if (slot.index >= photoCount) errors.push(`${f}.index ${slot.index} is out of range for photoCount ${photoCount}`);
      if (slot.x + slot.width <= 0 || slot.y + slot.height <= 0 || slot.x >= width || slot.y >= height) {
        errors.push(`${f} lies completely outside the ${width}x${height} canvas`);
      } else if (slot.x < 0 || slot.y < 0 || slot.x + slot.width > width || slot.y + slot.height > height) {
        warnings.push(`${f} extends past the canvas edge and will be clipped`);
      }
      if (slot.radius * 2 > Math.min(slot.width, slot.height)) warnings.push(`${f}.radius is larger than half the slot size`);
      photos.push(slot);
    });
    for (let i = 0; i < photoCount; i++) {
      if (!photos.some((s) => s.index === i)) errors.push(`no slot shows photo index ${i} (photoCount is ${photoCount})`);
    }
  }

  const texts: TextElement[] = [];
  if (json.texts !== undefined) {
    if (!Array.isArray(json.texts)) errors.push("texts must be an array");
    else json.texts.forEach((t: Record<string, unknown>, i: number) => {
      const f = `texts[${i}]`;
      const align = (t.align ?? "left") as TextElement["align"];
      if (!["left", "center", "right"].includes(align)) errors.push(`${f}.align must be left, center or right`);
      const x = num(t.x, `${f}.x`);
      texts.push({
        text: str(t.text, `${f}.text`),
        x,
        y: num(t.y, `${f}.y`),
        width: num(t.width, `${f}.width`, { min: 1, def: Math.max(1, width - x) }),
        fontSize: num(t.fontSize, `${f}.fontSize`, { min: 4, max: 2000, def: 48 }),
        fontFamily: str(t.fontFamily, `${f}.fontFamily`, "Helvetica, Arial, sans-serif"),
        fontWeight: String(t.fontWeight ?? "normal"),
        color: color(t.color, `${f}.color`, "#000000"),
        align,
        rotation: num(t.rotation, `${f}.rotation`, { min: -360, max: 360, def: 0 }),
      });
    });
  }

  const design: Design = {
    id,
    name: str(json.name, "name"),
    description: typeof json.description === "string" ? json.description : "",
    version: num(json.version, "version", { min: 1, int: true }),
    width,
    height,
    photoCount,
    backgroundColor: color(json.backgroundColor, "backgroundColor", "#ffffff"),
    background: asset(json.background, "background", false),
    foreground: asset(json.foreground, "foreground", false),
    preview: asset(json.preview, "preview", false),
    photos,
    texts,
    dir,
    fingerprint: "",
  };
  if (!design.background) warnings.push(`no background image; backgroundColor ${design.backgroundColor} is used`);
  if (!design.preview) warnings.push("no preview.png; the gallery will render a preview from the session photos");
  if (errors.length) return { design: null, errors, warnings };

  const h = createHash("sha1").update(raw);
  for (const a of [design.background, design.foreground]) {
    if (!a) continue;
    const st = fs.statSync(path.join(dir, a));
    h.update(`${a}:${st.size}:${st.mtimeMs}`);
  }
  design.fingerprint = h.digest("hex").slice(0, 12);
  return { design, errors, warnings };
}
