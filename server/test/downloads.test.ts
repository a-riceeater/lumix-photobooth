import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { inflateRawSync } from "node:zlib";
import { startServer, uploadSession } from "./helpers.js";

const binary = (res: any, cb: (err: Error | null, body: Buffer) => void) => {
  const chunks: Buffer[] = [];
  res.on("data", (c: Buffer) => chunks.push(c));
  res.on("end", () => cb(null, Buffer.concat(chunks)));
};

/** Minimal ZIP reader (local headers only) for verifying archive contents. */
function unzip(buf: Buffer): Map<string, Buffer> {
  const files = new Map<string, Buffer>();
  // Use the central directory for sizes (streamed entries use data descriptors).
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  let p = buf.readUInt32LE(eocd + 16);
  const n = buf.readUInt16LE(eocd + 10);
  for (let i = 0; i < n; i++) {
    const method = buf.readUInt16LE(p + 10);
    const size = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nameLen).toString();
    const dataStart = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
    const data = buf.subarray(dataStart, dataStart + size);
    files.set(name, method === 0 ? data : inflateRawSync(data));
    p += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

describe("downloads", () => {
  it("serves byte-identical originals and resized copies", async () => {
    const s = startServer();
    const { id, imgs } = await uploadSession(s);
    const orig = await s.agent.get(`/api/sessions/${id}/photos/1`).buffer(true).parse(binary).expect(200);
    expect(orig.body.equals(imgs[1])).toBe(true);
    expect(orig.headers["cache-control"]).toContain("immutable");
    const dl = await s.agent.get(`/api/sessions/${id}/photos/1?download=1`).buffer(true).parse(binary).expect(200);
    expect(dl.headers["content-disposition"]).toMatch(/attachment; filename="?test-event-.{6}-02\.jpg/);
    const thumb = await s.agent.get(`/api/sessions/${id}/photos/0?size=thumb`).buffer(true).parse(binary).expect(200);
    const meta = await sharp(thumb.body).metadata();
    expect(Math.max(meta.width!, meta.height!)).toBeLessThanOrEqual(480);
    await s.agent.get(`/api/sessions/${id}/photos/9`).expect(404);
    await s.agent.get(`/api/sessions/${id}/photos/0?size=huge`).expect(400);
  });

  it("renders strips for any compatible design, full size and preview", async () => {
    const s = startServer();
    const { id } = await uploadSession(s);
    for (const design of ["classic-white", "story-polaroid"]) {
      const full = await s.agent.get(`/api/sessions/${id}/strip?design=${design}&download=1`).buffer(true).parse(binary).expect(200);
      const m = await sharp(full.body).metadata();
      const d = s.ctx.designs.get(design)!;
      expect([m.width, m.height]).toEqual([d.width, d.height]);
      expect(full.headers["content-disposition"]).toContain(`${design}.jpg`);
      const prev = await s.agent.get(`/api/sessions/${id}/strip?design=${design}&size=preview`).buffer(true).parse(binary).expect(200);
      expect((await sharp(prev.body).metadata()).height!).toBeLessThan(d.height + 1);
    }
    // Default design when none is given; incompatible design is refused.
    await s.agent.get(`/api/sessions/${id}/strip`).expect(200);
    await s.agent.get(`/api/sessions/${id}/strip?design=grid-four`).expect(404);
    await s.agent.get(`/api/sessions/${id}/strip?design=nope`).expect(404);
  });

  it("generates a ZIP of all originals on demand", async () => {
    const s = startServer();
    const { id, imgs } = await uploadSession(s);
    const res = await s.agent.get(`/api/sessions/${id}/download`).buffer(true).parse(binary).expect(200);
    expect(res.headers["content-type"]).toBe("application/zip");
    const files = unzip(res.body);
    expect(files.size).toBe(3);
    const names = [...files.keys()].sort();
    names.forEach((n, i) => expect(files.get(n)!.equals(imgs[i])).toBe(true));
  });

  it("does not serve files of incomplete sessions", async () => {
    const s = startServer();
    const { id } = await uploadSession(s);
    s.ctx.db.prepare(`UPDATE sessions SET status = 'uploading' WHERE id = ?`).run(id);
    await s.agent.get(`/api/sessions/${id}/photos/0`).expect(404);
    await s.agent.get(`/api/sessions/${id}/download`).expect(404);
    await s.agent.get(`/api/sessions/${id}/strip`).expect(404);
  });
});
