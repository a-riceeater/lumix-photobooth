import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { newSessionId, sha256Hex } from "../src/ids.js";
import { auth, photos, startServer } from "./helpers.js";

const jpeg = { "Content-Type": "image/jpeg" };

async function newSession(s: ReturnType<typeof startServer>, count = 3) {
  const id = newSessionId();
  await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "uploads", photoCount: count }).expect(201);
  return id;
}

describe("photo uploads", () => {
  it("treats a repeated identical upload as a duplicate, not a new photo", async () => {
    const s = startServer();
    const id = await newSession(s);
    const [img] = await photos(1);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(img).expect(201);
    const again = await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(img).expect(200);
    expect(again.body.duplicate).toBe(true);
    expect(s.ctx.sessions.photos(id)).toHaveLength(1);
  });

  it("never overwrites an original with different content", async () => {
    const s = startServer();
    const id = await newSession(s);
    const [a, b] = await photos(2);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(a).expect(201);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(b).expect(409);
    const file = path.join(s.ctx.storage.originalPath("uploads", id, 0));
    expect(fs.readFileSync(file).equals(a)).toBe(true);
  });

  it("detects corrupted transfers via the declared checksum", async () => {
    const s = startServer();
    const id = await newSession(s);
    const [img] = await photos(1);
    const r = await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg)
      .set("X-Photo-SHA256", sha256Hex(Buffer.from("something else"))).send(img).expect(422);
    expect(r.body.error).toBe("checksum_mismatch");
    expect(s.ctx.sessions.photos(id)).toHaveLength(0);
  });

  it("rejects non-JPEG content, bad indexes and oversized files", async () => {
    const s = startServer(undefined, { MAX_UPLOAD_MB: "1" });
    const id = await newSession(s);
    const png = Buffer.from("89504e470d0a1a0a0000000d49484452", "hex");
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(png).expect(415);
    const fakeJpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(100)]);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(fakeJpeg).expect(415);
    const [img] = await photos(1);
    await s.agent.post(`/api/sessions/${id}/photos?index=3`).set(auth).set(jpeg).send(img).expect(400);
    await s.agent.post(`/api/sessions/${id}/photos?index=-1`).set(auth).set(jpeg).send(img).expect(400);
    await s.agent.post(`/api/sessions/${id}/photos`).set(auth).set(jpeg).send(img).expect(400);
    const big = Buffer.concat([img, Buffer.alloc(1.5 * 1024 * 1024)]);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(big).expect(413);
  });

  it("rejects images larger than the dimension limit", async () => {
    const s = startServer(undefined, { MAX_IMAGE_DIMENSION: "500" });
    const id = await newSession(s);
    const [img] = await photos(1, 0, 600);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(img).expect(400);
  });

  it("resumes an interrupted upload after a server restart", async () => {
    let s = startServer();
    const id = await newSession(s);
    const imgs = await photos(3);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(imgs[0]).expect(201);
    // Connection drops; the server restarts; the booth retries everything.
    s = s.restart();
    await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "uploads", photoCount: 3 }).expect(200);
    const status = await s.agent.get(`/api/sessions/${id}/status`).set(auth).expect(200);
    expect(status.body.missing).toEqual([1, 2]);
    for (let i = 0; i < 3; i++) await s.agent.post(`/api/sessions/${id}/photos?index=${i}`).set(auth).set(jpeg).send(imgs[i]);
    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({ sha256: imgs.map(sha256Hex) }).expect(200);
    s = s.restart();
    expect((await s.agent.get(`/api/sessions/${id}`).expect(200)).body.photos).toHaveLength(3);
  });

  it("recovers when a file was written but the database row was not (crash)", async () => {
    const s = startServer();
    const id = await newSession(s);
    const [a, b] = await photos(2);
    const dest = s.ctx.storage.originalPath("uploads", id, 0);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    // Same bytes on disk without a row: adopted.
    fs.writeFileSync(dest, a);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(a).expect(201);
    expect(s.ctx.sessions.photo(id, 0)?.sha256).toBe(sha256Hex(a));
    // Different orphaned bytes: moved aside, not deleted.
    const dest1 = s.ctx.storage.originalPath("uploads", id, 1);
    fs.writeFileSync(dest1, a);
    await s.agent.post(`/api/sessions/${id}/photos?index=1`).set(auth).set(jpeg).send(b).expect(201);
    expect(fs.readFileSync(dest1).equals(b)).toBe(true);
    expect(fs.readdirSync(path.dirname(dest1)).some((f) => f.startsWith(".orphan-"))).toBe(true);
  });

  it("handles concurrent duplicate uploads safely", async () => {
    const s = startServer();
    const id = await newSession(s);
    const [img] = await photos(1);
    const results = await Promise.all(Array.from({ length: 5 }, () =>
      s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(img)));
    expect(results.filter((r) => r.status === 201)).toHaveLength(1);
    expect(results.every((r) => [200, 201].includes(r.status))).toBe(true);
    expect(s.ctx.sessions.photos(id)).toHaveLength(1);
  });

  it("rejects uploads to completed sessions unless identical", async () => {
    const s = startServer();
    const id = await newSession(s, 1);
    const [a, b] = await photos(2);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(a).expect(201);
    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({}).expect(200);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(a).expect(200);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(b).expect(409);
  });

  it("does not allow path traversal through ids", async () => {
    const s = startServer();
    for (const bad of ["..%2F..%2Fetc", "....................../x", "%2e%2e%2f%2e%2e%2f%2e%2e%2f%2e%2e%2f"]) {
      const r = await s.agent.get(`/api/sessions/${bad}/photos/0`);
      expect([400, 404]).toContain(r.status);
    }
    await s.agent.post("/api/sessions").set(auth).send({ id: "../../../../../../../../tmp/x", eventId: "e", photoCount: 1 }).expect(400);
    await s.agent.post("/api/sessions").set(auth).send({ id: newSessionId(), eventId: "../x", photoCount: 1 }).expect(400);
    expect(() => s.ctx.storage.sessionDir("..", newSessionId())).toThrow();
    await s.agent.get("/api/sessions/AAAAAAAAAAAAAAAAAAAAAA/strip?design=../../etc").expect(404);
  });
});
