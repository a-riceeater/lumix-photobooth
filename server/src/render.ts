import path from "node:path";
import sharp, { type OverlayOptions } from "sharp";
import type { Design, PhotoSlot, TextElement } from "./designs.js";

// libvips caches decoded images by default; with 24 MP originals that only
// costs memory in a long-running server.
sharp.cache(false);

export interface RenderOptions {
  /** Output scale relative to the design canvas (1 = full resolution). */
  scale?: number;
  eventName?: string;
  /** Session capture time, used for {date} / {time}. */
  date?: Date;
  quality?: number;
}

/** Limits concurrent renders: full-resolution strips decode several 24 MP JPEGs. */
class Semaphore {
  private queue: (() => void)[] = [];
  private active = 0;
  constructor(private readonly max: number) {}
  async run<T>(fn: () => Promise<T>): Promise<T> {
    if (this.active >= this.max) await new Promise<void>((r) => this.queue.push(r));
    this.active++;
    try {
      return await fn();
    } finally {
      this.active--;
      this.queue.shift()?.();
    }
  }
}
export const renderLimiter = new Semaphore(2);

/**
 * Renders a design. Layer order: background colour, background PNG, photos
 * (in slot order), foreground PNG, text. `photos[i]` is the image for session
 * photo index i (file path or buffer). Returns a JPEG buffer.
 */
export async function renderDesign(design: Design, photos: (string | Buffer)[], opts: RenderOptions = {}): Promise<Buffer> {
  const s = opts.scale ?? 1;
  const W = Math.max(1, Math.round(design.width * s));
  const H = Math.max(1, Math.round(design.height * s));
  if (photos.length < design.photoCount) {
    throw new Error(`design ${design.id} needs ${design.photoCount} photos, got ${photos.length}`);
  }
  const layers: OverlayOptions[] = [];

  if (design.background) {
    const bg = await sharp(path.join(design.dir, design.background)).resize(W, H, { fit: "fill" }).png().toBuffer();
    layers.push({ input: bg, left: 0, top: 0 });
  }
  for (const slot of design.photos) {
    const placed = await renderSlot(slot, photos[slot.index], s, W, H);
    if (placed) layers.push(placed);
  }
  if (design.foreground) {
    const fg = await sharp(path.join(design.dir, design.foreground)).resize(W, H, { fit: "fill" }).png().toBuffer();
    layers.push({ input: fg, left: 0, top: 0 });
  }
  if (design.texts.length) {
    layers.push({ input: Buffer.from(textSvg(design.texts, W, H, s, opts)), left: 0, top: 0 });
  }

  return sharp({ create: { width: W, height: H, channels: 4, background: design.backgroundColor } })
    .composite(layers)
    .flatten({ background: design.backgroundColor })
    .jpeg({ quality: opts.quality ?? (s >= 1 ? 95 : 82), chromaSubsampling: s >= 1 ? "4:4:4" : "4:2:0", mozjpeg: s < 1 })
    .toBuffer();
}

async function renderSlot(slot: PhotoSlot, input: string | Buffer, s: number, W: number, H: number): Promise<OverlayOptions | null> {
  const sw = Math.max(1, Math.round(slot.width * s));
  const sh = Math.max(1, Math.round(slot.height * s));
  // .rotate() with no angle applies the EXIF orientation of the original.
  let img = await sharp(input)
    .rotate()
    .resize(sw, sh, {
      fit: slot.fit,
      position: "centre",
      kernel: "lanczos3",
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .ensureAlpha()
    .png()
    .toBuffer();

  if (slot.radius > 0) {
    const r = Math.min(slot.radius * s, sw / 2, sh / 2);
    const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${sw}" height="${sh}"><rect width="${sw}" height="${sh}" rx="${r}" ry="${r}" fill="#fff"/></svg>`);
    img = await sharp(img).composite([{ input: mask, blend: "dest-in" }]).png().toBuffer();
  }

  // Rotation is around the slot centre; the rotated bounding box grows.
  let w = sw;
  let h = sh;
  if (slot.rotation % 360 !== 0) {
    const rotated = sharp(img).rotate(slot.rotation, { background: { r: 0, g: 0, b: 0, alpha: 0 } });
    const { data, info } = await rotated.png().toBuffer({ resolveWithObject: true });
    img = data;
    w = info.width;
    h = info.height;
  }
  const cx = (slot.x + slot.width / 2) * s;
  const cy = (slot.y + slot.height / 2) * s;
  return clipToCanvas(img, Math.round(cx - w / 2), Math.round(cy - h / 2), w, h, W, H);
}

/** sharp cannot composite outside the canvas, so crop overhanging parts. */
async function clipToCanvas(img: Buffer, left: number, top: number, w: number, h: number, W: number, H: number): Promise<OverlayOptions | null> {
  const x0 = Math.max(0, left);
  const y0 = Math.max(0, top);
  const x1 = Math.min(W, left + w);
  const y1 = Math.min(H, top + h);
  if (x1 <= x0 || y1 <= y0) return null;
  if (x0 === left && y0 === top && x1 === left + w && y1 === top + h) return { input: img, left, top };
  const cropped = await sharp(img)
    .extract({ left: x0 - left, top: y0 - top, width: x1 - x0, height: y1 - y0 })
    .png()
    .toBuffer();
  return { input: cropped, left: x0, top: y0 };
}

function escapeXml(s: string): string {
  return s.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" })[c]!);
}

export function fillPlaceholders(text: string, opts: RenderOptions): string {
  const d = opts.date ?? new Date();
  return text
    .replaceAll("{eventName}", opts.eventName ?? "")
    .replaceAll("{date}", d.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" }))
    .replaceAll("{time}", d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }));
}

function textSvg(texts: TextElement[], W: number, H: number, s: number, opts: RenderOptions): string {
  const parts = texts.map((t) => {
    const anchor = t.align === "center" ? "middle" : t.align === "right" ? "end" : "start";
    const ax = (t.align === "center" ? t.x + t.width / 2 : t.align === "right" ? t.x + t.width : t.x) * s;
    const ay = t.y * s;
    const rot = t.rotation ? ` transform="rotate(${t.rotation} ${ax} ${ay})"` : "";
    return `<text x="${ax}" y="${ay}" text-anchor="${anchor}" font-family="${escapeXml(t.fontFamily)}" ` +
      `font-size="${t.fontSize * s}" font-weight="${escapeXml(t.fontWeight)}" fill="${t.color}"${rot}>` +
      `${escapeXml(fillPlaceholders(t.text, opts))}</text>`;
  });
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${parts.join("")}</svg>`;
}

/** Scale that fits the design's longest side into `maxSide` pixels (never > 1). */
export function previewScale(design: Design, maxSide = 1600): number {
  return Math.min(1, maxSide / Math.max(design.width, design.height));
}
