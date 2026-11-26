import path from "node:path";
import sharp from "sharp";
import type { SessionRow } from "./db.js";
import type { Design } from "./designs.js";
import { previewScale, renderDesign, renderLimiter } from "./render.js";
import { fileExists, Storage } from "./storage.js";

export type PhotoSize = "thumb" | "medium" | "original";
export const PHOTO_SIZES: Record<Exclude<PhotoSize, "original">, number> = { thumb: 480, medium: 1600 };

/**
 * Derived images (thumbnails, strips) are cached next to the originals and
 * created at most once concurrently per file. Originals are only ever read.
 */
export class ImageService {
  private inflight = new Map<string, Promise<string>>();

  constructor(private readonly storage: Storage) {}

  private once(key: string, make: () => Promise<string>): Promise<string> {
    let p = this.inflight.get(key);
    if (!p) {
      p = make().finally(() => this.inflight.delete(key));
      this.inflight.set(key, p);
    }
    return p;
  }

  originalPath(session: SessionRow, index: number): string {
    return this.storage.originalPath(session.event_id, session.id, index);
  }

  /** Path of a resized copy (EXIF orientation applied), generated on first use. */
  async photoPath(session: SessionRow, index: number, size: PhotoSize): Promise<string> {
    const original = this.originalPath(session, index);
    if (size === "original") return original;
    const out = path.join(this.storage.thumbnailsDir(session.event_id, session.id), `${String(index + 1).padStart(2, "0")}-${size}.jpg`);
    if (await fileExists(out)) return out;
    return this.once(out, async () => {
      const max = PHOTO_SIZES[size];
      const buf = await renderLimiter.run(() =>
        sharp(original).rotate().resize(max, max, { fit: "inside", withoutEnlargement: true }).jpeg({ quality: 82, mozjpeg: true }).toBuffer(),
      );
      await this.storage.writeReplace(out, buf);
      return out;
    });
  }

  /**
   * Path of a rendered strip. Previews are rendered from the medium-size
   * copies at reduced resolution; full renders use the untouched originals.
   * The cache key includes the design fingerprint, so editing a design
   * invalidates old renders automatically.
   */
  async stripPath(session: SessionRow, design: Design, full: boolean, eventName: string): Promise<string> {
    const kind = full ? "full" : "preview";
    const out = path.join(this.storage.generatedDir(session.event_id, session.id), `${design.id}-${design.fingerprint}-${kind}.jpg`);
    if (await fileExists(out)) return out;
    return this.once(out, async () => {
      const inputs: string[] = [];
      for (let i = 0; i < design.photoCount; i++) {
        inputs.push(full ? this.originalPath(session, i) : await this.photoPath(session, i, "medium"));
      }
      const date = new Date(session.captured_at ?? session.created_at);
      const buf = await renderLimiter.run(() =>
        renderDesign(design, inputs, { scale: full ? 1 : previewScale(design), eventName, date }),
      );
      await this.storage.writeReplace(out, buf);
      return out;
    });
  }

  /** Design thumbnail for designs without preview.png: grey placeholders. */
  async placeholderPreview(design: Design): Promise<Buffer> {
    const tile = await sharp({ create: { width: 300, height: 200, channels: 3, background: "#9aa3ad" } }).jpeg().toBuffer();
    const inputs = Array.from({ length: design.photoCount }, () => tile);
    return renderDesign(design, inputs, { scale: previewScale(design, 600), eventName: "Event Name" });
  }
}
