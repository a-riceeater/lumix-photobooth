import { describe, expect, it } from "vitest";
import { ADMIN_PASSWORD, auth, startServer, uploadSession } from "./helpers.js";

const cookieOf = (res: { headers: Record<string, unknown> }) =>
  ((res.headers["set-cookie"] as string[] | undefined) ?? []).map((c) => c.split(";")[0]).join("; ");

describe("gallery access", () => {
  it("keeps event galleries disabled by default while session links work", async () => {
    const s = startServer();
    const { id } = await uploadSession(s, { eventId: "private-party" });
    await s.agent.get("/gallery/private-party").expect(404);
    await s.agent.get("/api/events/private-party").expect(404);
    await s.agent.get("/api/events/private-party/sessions").expect(404);
    await s.agent.get(`/s/${id}`).expect(200);
    await s.agent.get(`/api/sessions/${id}`).expect(200);
  });

  it("honours PUBLIC_EVENT_GALLERY for new events", async () => {
    const s = startServer(undefined, { PUBLIC_EVENT_GALLERY: "true" });
    await uploadSession(s, { eventId: "open-party" });
    await s.agent.get("/gallery/open-party").expect(200);
  });

  it("serves a paginated public event gallery without private data", async () => {
    const s = startServer();
    for (let i = 0; i < 3; i++) await uploadSession(s, { eventId: "pub" });
    s.ctx.db.prepare(`UPDATE events SET gallery_mode = 'public' WHERE id = 'pub'`).run();
    await s.agent.post(`/api/sessions/${(await uploadSession(s, { eventId: "pub" })).id}/email`).set(auth).send({ email: "secret@example.com" });
    const ev = await s.agent.get("/api/events/pub").expect(200);
    expect(ev.body.sessionCount).toBe(4);
    const p1 = await s.agent.get("/api/events/pub/sessions?limit=3").expect(200);
    expect(p1.body.sessions).toHaveLength(3);
    expect(p1.body.nextOffset).toBe(3);
    const p2 = await s.agent.get("/api/events/pub/sessions?limit=3&offset=3").expect(200);
    expect(p2.body.sessions).toHaveLength(1);
    expect(p2.body.nextOffset).toBeNull();
    const all = JSON.stringify([ev.body, p1.body, p2.body]);
    expect(all).not.toContain("secret");
    expect(all).not.toMatch(/device|password|@/);
  });

  it("protects password galleries and accepts the right password", async () => {
    const s = startServer();
    await uploadSession(s, { eventId: "locked" });
    const admin = await s.agent.post("/admin/login").type("form").send({ password: ADMIN_PASSWORD }).expect(303);
    const adminCookie = cookieOf(admin);
    await s.agent.patch("/api/admin/events/locked").set("Cookie", adminCookie).send({ galleryMode: "password", galleryPassword: "letmein" }).expect(200);

    await s.agent.get("/gallery/locked").expect(401);
    await s.agent.get("/api/events/locked/sessions").expect(401);
    const wrong = await s.agent.post("/gallery/locked/login").type("form").send({ password: "nope" }).expect(303);
    expect(wrong.headers.location).toContain("error=1");
    const ok = await s.agent.post("/gallery/locked/login").type("form").send({ password: "letmein" }).expect(303);
    const cookie = cookieOf(ok);
    await s.agent.get("/gallery/locked").set("Cookie", cookie).expect(200);
    await s.agent.get("/api/events/locked/sessions").set("Cookie", cookie).expect(200);

    // Changing the password invalidates existing gallery cookies.
    await s.agent.patch("/api/admin/events/locked").set("Cookie", adminCookie).send({ galleryPassword: "newpass" }).expect(200);
    await s.agent.get("/api/events/locked/sessions").set("Cookie", cookie).expect(401);
    // A forged cookie is rejected.
    await s.agent.get("/api/events/locked/sessions").set("Cookie", "pb_gallery_locked=abc.123.def").expect(401);
  });

  it("requires admin authentication for admin endpoints", async () => {
    const s = startServer();
    const { id } = await uploadSession(s, { eventId: "adm" });
    await s.agent.get("/api/admin/overview").expect(401);
    await s.agent.delete(`/api/admin/sessions/${id}`).expect(401);
    await s.agent.get("/api/admin/overview").set(auth).expect(401); // device key is not admin
    const basic = "Basic " + Buffer.from(`admin:${ADMIN_PASSWORD}`).toString("base64");
    const ov = await s.agent.get("/api/admin/overview").set("Authorization", basic).expect(200);
    expect(ov.body.events[0]).toMatchObject({ id: "adm", complete: 1 });
    // Mutations must be JSON (no cross-site form posts).
    await s.agent.delete(`/api/admin/sessions/${id}`).set("Authorization", basic).type("form").send("x=1").expect(415);
    await s.agent.delete(`/api/admin/sessions/${id}`).set("Authorization", basic).set("Content-Type", "application/json").send("{}").expect(200);
    await s.agent.get(`/api/sessions/${id}`).expect(202);
  });

  it("deletes events only with explicit confirmation", async () => {
    const s = startServer();
    const { id } = await uploadSession(s, { eventId: "gone" });
    const basic = "Basic " + Buffer.from(`:${ADMIN_PASSWORD}`).toString("base64");
    await s.agent.delete("/api/admin/events/gone").set("Authorization", basic).send({}).expect(400);
    await s.agent.delete("/api/admin/events/gone").set("Authorization", basic).send({ confirm: "gone" }).expect(200);
    await s.agent.get(`/api/sessions/${id}`).expect(202);
    expect(s.ctx.sessions.getEvent("gone")).toBeUndefined();
  });

  it("sends security headers and no-cache for API responses", async () => {
    const s = startServer();
    const r = await s.agent.get("/api/health").expect(200);
    expect(r.headers["x-content-type-options"]).toBe("nosniff");
    expect(r.headers["content-security-policy"]).toContain("default-src 'self'");
    expect(r.headers["cache-control"]).toBe("no-store");
    await s.agent.get("/api/nope").expect(404);
    await s.agent.get("/s/not-a-valid-id").expect(404);
  });
});
