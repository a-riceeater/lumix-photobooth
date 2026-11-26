import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { newSessionId, sha256Hex } from "../src/ids.js";
import { auth, photos, startServer, uploadSession } from "./helpers.js";

const jpeg = { "Content-Type": "image/jpeg" };

describe("session lifecycle", () => {
  it("creates sessions idempotently and rejects conflicting reuse", async () => {
    const s = startServer();
    const id = newSessionId();
    const body = { id, eventId: "party", eventName: "Party", photoCount: 3 };
    const first = await s.agent.post("/api/sessions").set(auth).send(body).expect(201);
    expect(first.body.galleryUrl).toBe(`https://photos.example.test/s/${id}`);
    const again = await s.agent.post("/api/sessions").set(auth).send(body).expect(200);
    expect(again.body.created).toBe(false);
    await s.agent.post("/api/sessions").set(auth).send({ ...body, photoCount: 4 }).expect(409);
    expect(s.ctx.sessions.getEvent("party")?.name).toBe("Party");
  });

  it("requires the device key for uploads and modifications", async () => {
    const s = startServer();
    const id = newSessionId();
    await s.agent.post("/api/sessions").send({ id, eventId: "e", photoCount: 1 }).expect(401);
    await s.agent.post("/api/sessions").set({ Authorization: "Bearer wrong-key-wrong-key" }).send({ id, eventId: "e", photoCount: 1 }).expect(401);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(jpeg).send(Buffer.from("x")).expect(401);
    await s.agent.post(`/api/sessions/${id}/complete`).send({}).expect(401);
    await s.agent.post(`/api/sessions/${id}/email`).send({ email: "a@b.co" }).expect(401);
    await s.agent.get(`/api/sessions/${id}/status`).expect(401);
  });

  it("validates request parameters", async () => {
    const s = startServer();
    await s.agent.post("/api/sessions").set(auth).send({ id: "short", eventId: "e", photoCount: 3 }).expect(400);
    await s.agent.post("/api/sessions").set(auth).send({ id: newSessionId(), eventId: "Bad Event", photoCount: 3 }).expect(400);
    await s.agent.post("/api/sessions").set(auth).send({ id: newSessionId(), eventId: "e", photoCount: 0 }).expect(400);
    await s.agent.post("/api/sessions").set(auth).send({ id: newSessionId(), eventId: "e", photoCount: 3, capturedAt: "nope" }).expect(400);
    await s.agent.post("/api/sessions").set(auth).set("Content-Type", "application/json").send("{bad json").expect(400);
  });

  it("runs the full upload → complete → public view flow", async () => {
    const s = startServer();
    const id = newSessionId();
    const imgs = await photos(3);
    await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "e1", photoCount: 3 }).expect(201);
    // Not visible to guests until complete; unknown and pending look the same.
    expect((await s.agent.get(`/api/sessions/${id}`).expect(202)).body.status).toBe("processing");
    expect((await s.agent.get(`/api/sessions/${newSessionId()}`).expect(202)).body.status).toBe("processing");

    for (let i = 0; i < 3; i++) {
      const r = await s.agent.post(`/api/sessions/${id}/photos?index=${i}&sha256=${sha256Hex(imgs[i])}`).set(auth).set(jpeg).send(imgs[i]).expect(201);
      expect(r.body).toMatchObject({ index: i, duplicate: false, width: 600, height: 400 });
    }
    const status = await s.agent.get(`/api/sessions/${id}/status`).set(auth).expect(200);
    expect(status.body.missing).toEqual([]);
    expect(status.body.photos.map((p: { sha256: string }) => p.sha256)).toEqual(imgs.map(sha256Hex));

    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({ sha256: imgs.map(sha256Hex) }).expect(200);
    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({}).expect(200); // idempotent
    const view = await s.agent.get(`/api/sessions/${id}`).expect(200);
    expect(view.body.photos).toHaveLength(3);
    expect(view.body.designs.every((d: { photoCount: number }) => d.photoCount === 3)).toBe(true);
    expect(view.body.designs.map((d: { id: string }) => d.id)).not.toContain("grid-four");
    expect(JSON.stringify(view.body)).not.toMatch(/sha256|device|@/);

    // Originals are stored byte-for-byte at the documented path.
    const file = path.join(s.dataDir, "events", "e1", "sessions", id, "originals", "02.jpg");
    expect(fs.readFileSync(file).equals(imgs[1])).toBe(true);
  });

  it("refuses to complete a session with missing photos", async () => {
    const s = startServer();
    const id = newSessionId();
    const [img] = await photos(1);
    await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "e", photoCount: 3 }).expect(201);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(img).expect(201);
    const r = await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({}).expect(409);
    expect(r.body.missing).toEqual([1, 2]);
  });

  it("rejects completion when the device's checksums differ", async () => {
    const s = startServer();
    const id = newSessionId();
    const [img] = await photos(1);
    await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "e", photoCount: 1 }).expect(201);
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set(jpeg).send(img).expect(201);
    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({ sha256: ["0".repeat(64)] }).expect(409);
  });
});
