import { badRequest } from "./errors.js";

/**
 * Builder for admin-made themes. A theme is an ordinary design folder; the
 * builder parameters are stored in design.json under "builder" so the admin
 * page can edit it again. Layouts are computed here — no hand-written slots.
 */

export type PhotoShape = "keep" | "fill";
export type TextPosition = "bottom" | "top" | "none";

export interface SingleColumnParams {
  layout: "single-column";
  name: string;
  description: string;
  width: number;
  height: number;
  photoCount: number;
  /** Outer margin around the photo column, px. */
  margin: number;
  /** Space between photos, px. */
  gap: number;
  /** Distance from the top of the photo area to the first photo, px; null = centred. */
  topMargin: number | null;
  /** keep = 3:2 photos, no cropping; fill = photos stretch to the column (cropped). */
  photoShape: PhotoShape;
  cornerRadius: number;
  backgroundColor: string;
  textPosition: TextPosition;
  /** Reserved height for the text block (px); ignored when textPosition is none. */
  textAreaHeight: number;
  title: string;
  subtitle: string;
  fontFamily: string;
  titleSize: number;
  subtitleSize: number;
  textColor: string;
  subtitleColor: string;
  bold: boolean;
}

export const SINGLE_COLUMN_DEFAULTS: SingleColumnParams = {
  layout: "single-column",
  name: "My theme",
  description: "",
  width: 1200,
  height: 3600,
  photoCount: 3,
  margin: 60,
  gap: 60,
  topMargin: null,
  photoShape: "keep",
  cornerRadius: 0,
  backgroundColor: "#ffffff",
  textPosition: "bottom",
  textAreaHeight: 600,
  title: "{eventName}",
  subtitle: "{date}",
  fontFamily: "Georgia, serif",
  titleSize: 92,
  subtitleSize: 56,
  textColor: "#18181b",
  subtitleColor: "#71717a",
  bold: true,
};

export const FONT_CHOICES = [
  "Georgia, serif",
  "Helvetica, Arial, sans-serif",
  "'Times New Roman', serif",
  "'Courier New', monospace",
  "'Trebuchet MS', sans-serif",
];

const HEX = /^#[0-9a-fA-F]{6}$/;
const PHOTO_ASPECT = 3 / 2;

/** Coerces and validates user input against the defaults; throws 400 with a clear message. */
export function normalizeParams(input: unknown): SingleColumnParams {
  const raw = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const p: SingleColumnParams = { ...SINGLE_COLUMN_DEFAULTS };
  const num = (k: keyof SingleColumnParams, min: number, max: number) => {
    if (raw[k] === undefined || raw[k] === "") return;
    const v = Number(raw[k]);
    if (!Number.isFinite(v) || v < min || v > max) throw badRequest(`${k} must be between ${min} and ${max}`);
    (p as unknown as Record<string, unknown>)[k] = Math.round(v);
  };
  const str = (k: keyof SingleColumnParams, max: number) => {
    if (raw[k] === undefined) return;
    if (typeof raw[k] !== "string" || (raw[k] as string).length > max) throw badRequest(`${k} must be text up to ${max} characters`);
    (p as unknown as Record<string, unknown>)[k] = (raw[k] as string).replace(/[\u0000-\u001f]/g, "");
  };
  const color = (k: keyof SingleColumnParams) => {
    if (raw[k] === undefined) return;
    if (typeof raw[k] !== "string" || !HEX.test(raw[k] as string)) throw badRequest(`${k} must be a colour like #336699`);
    (p as unknown as Record<string, unknown>)[k] = raw[k];
  };
  if (raw.layout !== undefined && raw.layout !== "single-column") throw badRequest("Unknown layout");
  str("name", 60);
  if (!p.name.trim()) throw badRequest("Give the theme a name");
  p.name = p.name.trim();
  str("description", 200);
  num("width", 300, 8000);
  num("height", 300, 12000);
  num("photoCount", 1, 8);
  num("margin", 0, 2000);
  num("gap", 0, 2000);
  if (raw.topMargin === null || raw.topMargin === "" || raw.topMargin === undefined) {
    p.topMargin = raw.topMargin === undefined ? p.topMargin : null;
  } else {
    const v = Number(raw.topMargin);
    if (!Number.isFinite(v) || v < 0 || v > 4000) throw badRequest("topMargin must be between 0 and 4000 (or empty for centred)");
    p.topMargin = Math.round(v);
  }
  num("cornerRadius", 0, 500);
  num("textAreaHeight", 0, 4000);
  num("titleSize", 8, 600);
  num("subtitleSize", 8, 600);
  color("backgroundColor");
  color("textColor");
  color("subtitleColor");
  str("title", 120);
  str("subtitle", 120);
  if (raw.photoShape !== undefined) {
    if (raw.photoShape !== "keep" && raw.photoShape !== "fill") throw badRequest("photoShape must be keep or fill");
    p.photoShape = raw.photoShape;
  }
  if (raw.textPosition !== undefined) {
    if (!["bottom", "top", "none"].includes(raw.textPosition as string)) throw badRequest("textPosition must be bottom, top or none");
    p.textPosition = raw.textPosition as TextPosition;
  }
  if (raw.fontFamily !== undefined) {
    if (typeof raw.fontFamily !== "string" || !/^[\w\s,'"-]{1,80}$/.test(raw.fontFamily)) throw badRequest("fontFamily has invalid characters");
    p.fontFamily = raw.fontFamily;
  }
  if (raw.bold !== undefined) p.bold = raw.bold === true || raw.bold === "true";
  return p;
}

export interface BuiltLayout {
  photos: { index: number; x: number; y: number; width: number; height: number; fit: "cover"; radius?: number }[];
  texts: Record<string, unknown>[];
}

/**
 * One column of photos. The text block reserves `textAreaHeight` at the top or
 * bottom; photos fill the rest. "keep" uses 3:2 photos (shrinking them if the
 * column is too short); "fill" stretches each photo to the available height
 * (cropped by `cover`). The photo block is centred in its area.
 */
export function layoutSingleColumn(p: SingleColumnParams): BuiltLayout {
  const textH = p.textPosition === "none" ? 0 : Math.min(p.textAreaHeight, p.height - 2 * p.margin - 100);
  const areaTop = p.textPosition === "top" ? textH : 0;
  const areaH = p.height - textH;
  const colW = p.width - 2 * p.margin;
  // Photo size never depends on the top margin: it only moves the stack.
  const availH = areaH - 2 * p.margin - (p.photoCount - 1) * p.gap;
  if (colW < 20 || availH < 20 * p.photoCount) {
    throw badRequest("The photos don't fit: reduce the margins, gap, text area or number of photos, or make the canvas larger");
  }
  let photoW = colW;
  let photoH = availH / p.photoCount;
  if (p.photoShape === "keep") {
    photoH = Math.min(colW / PHOTO_ASPECT, photoH);
    photoW = photoH * PHOTO_ASPECT;
  }
  photoW = Math.floor(photoW);
  photoH = Math.floor(photoH);
  const blockH = p.photoCount * photoH + (p.photoCount - 1) * p.gap;
  const y0 = p.topMargin === null
    ? Math.round(areaTop + (areaH - blockH) / 2)
    : areaTop + p.topMargin;
  const x = Math.round((p.width - photoW) / 2);
  const photos = Array.from({ length: p.photoCount }, (_, i) => ({
    index: i,
    x,
    y: y0 + i * (photoH + p.gap),
    width: photoW,
    height: photoH,
    fit: "cover" as const,
    ...(p.cornerRadius > 0 ? { radius: p.cornerRadius } : {}),
  }));

  const texts: Record<string, unknown>[] = [];
  if (p.textPosition !== "none") {
    const blockTop = p.textPosition === "top" ? 0 : p.height - textH;
    const lines = [
      p.title.trim() ? { text: p.title, size: p.titleSize, color: p.textColor, weight: p.bold ? "bold" : "normal" } : null,
      p.subtitle.trim() ? { text: p.subtitle, size: p.subtitleSize, color: p.subtitleColor, weight: "normal" } : null,
    ].filter(Boolean) as { text: string; size: number; color: string; weight: string }[];
    const spacing = 0.45;
    const total = lines.reduce((h, l, i) => h + l.size + (i ? l.size * spacing : 0), 0);
    let baseline = blockTop + (textH - total) / 2;
    lines.forEach((l, i) => {
      baseline += l.size + (i ? l.size * spacing : 0);
      texts.push({
        text: l.text, x: p.margin, y: Math.round(baseline - l.size * 0.2), width: p.width - 2 * p.margin, align: "center",
        fontSize: l.size, fontWeight: l.weight, fontFamily: p.fontFamily, color: l.color,
      });
    });
  }
  return { photos, texts };
}

/** Human-readable layout problems that don't block saving (e.g. a top margin pushing photos off). */
export function layoutWarnings(p: SingleColumnParams): string[] {
  const { photos } = layoutSingleColumn(p);
  const last = photos[photos.length - 1];
  const bottom = last.y + last.height;
  const out: string[] = [];
  if (bottom > p.height) out.push(`The last photo runs ${bottom - p.height} px past the bottom of the canvas — lower the top margin.`);
  else if (p.textPosition === "bottom" && bottom > p.height - p.textAreaHeight) out.push("The photos overlap the text area.");
  if (p.textPosition === "top" && p.topMargin !== null && p.topMargin < p.textAreaHeight) out.push("The photos overlap the text area.");
  return out;
}

/** design.json content for a builder theme (assets are added by the caller). */
export function designJson(id: string, version: number, p: SingleColumnParams,
                           assets: { background: boolean; foreground: boolean }, enabled = true): Record<string, unknown> {
  const { photos, texts } = layoutSingleColumn(p);
  return {
    id,
    name: p.name,
    description: p.description || `Single column, ${p.photoCount} photos`,
    version,
    width: p.width,
    height: p.height,
    photoCount: p.photoCount,
    backgroundColor: p.backgroundColor,
    background: assets.background ? "background.png" : null,
    foreground: assets.foreground ? "foreground.png" : null,
    preview: "preview.png",
    ...(enabled ? {} : { enabled: false }),
    photos,
    texts,
    builder: p,
  };
}
