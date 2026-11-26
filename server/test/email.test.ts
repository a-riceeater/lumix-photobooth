import { describe, expect, it } from "vitest";
import { newSessionId } from "../src/ids.js";
import { renderGalleryEmail } from "../src/email.js";
import { auth, photos, startServer, uploadSession } from "./helpers.js";

describe("email queue", () => {
  it("queues while uploading and delivers once the session is complete", async () => {
    const s = startServer();
    const id = newSessionId();
    const [img] = await photos(1);
    await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "mail", eventName: "Mail Party", photoCount: 1 }).expect(201);
    await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "guest@example.com" }).expect(202);
    await s.ctx.email.processDue();
    expect(s.mail.sent).toHaveLength(0);

    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set("Content-Type", "image/jpeg").send(img).expect(201);
    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({}).expect(200);
    await s.ctx.email.processDue();
    expect(s.mail.sent).toHaveLength(1);
    const msg = s.mail.sent[0];
    expect(msg.to).toBe("guest@example.com");
    expect(msg.subject).toBe("Your photos from Mail Party");
    expect(msg.text).toContain(`https://photos.example.test/s/${id}`);
    expect(msg.html).toContain(`https://photos.example.test/s/${id}`);
    // Address is forgotten after delivery; only a masked form remains.
    const row = s.ctx.db.prepare(`SELECT * FROM emails`).get() as { address: string | null; masked: string; status: string };
    expect(row).toMatchObject({ address: null, masked: "g***@example.com", status: "sent" });
  });

  it("is idempotent for the same address and limits recipients per session", async () => {
    const s = startServer(undefined, { EMAIL_MAX_PER_SESSION: "2" });
    const { id } = await uploadSession(s);
    await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "a@example.com" }).expect(202);
    const dup = await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "A@example.com" }).expect(200);
    expect(dup.body.duplicate).toBe(true);
    await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "b@example.com" }).expect(202);
    await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "c@example.com" }).expect(429);
  });

  it("enforces the hourly cap", async () => {
    const s = startServer(undefined, { EMAIL_MAX_PER_HOUR: "1" });
    const a = await uploadSession(s);
    const b = await uploadSession(s);
    await s.agent.post(`/api/sessions/${a.id}/email`).set(auth).send({ email: "a@example.com" }).expect(202);
    await s.agent.post(`/api/sessions/${b.id}/email`).set(auth).send({ email: "b@example.com" }).expect(429);
  });

  it("validates addresses and unknown sessions", async () => {
    const s = startServer();
    const { id } = await uploadSession(s);
    for (const bad of ["", "nope", "a@b", "a b@example.com", "x@example.com\r\nBcc: z@example.com", "a".repeat(300) + "@x.com", 42]) {
      await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: bad }).expect(400);
    }
    await s.agent.post(`/api/sessions/${newSessionId()}/email`).set(auth).send({ email: "a@example.com" }).expect(404);
  });

  it("retries transient SMTP failures and gives up on permanent ones", async () => {
    const s = startServer();
    const { id } = await uploadSession(s);
    s.mail.failWith = Object.assign(new Error("connection refused"), { code: "ECONNECTION" });
    await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "a@example.com" }).expect(202);
    await s.ctx.email.processDue();
    let row = s.ctx.db.prepare(`SELECT * FROM emails`).get() as { status: string; attempts: number; next_attempt_at: string; address: string };
    expect(row.status).toBe("pending");
    expect(row.attempts).toBe(1);
    expect(new Date(row.next_attempt_at).getTime()).toBeGreaterThan(Date.now());
    expect(row.address).toBe("a@example.com");

    // Not due yet: nothing happens. Then make it due and let SMTP recover.
    await s.ctx.email.processDue();
    expect(s.mail.sent).toHaveLength(0);
    s.ctx.db.prepare(`UPDATE emails SET next_attempt_at = ?`).run(new Date(0).toISOString());
    s.mail.failWith = null;
    await s.ctx.email.processDue();
    expect(s.mail.sent).toHaveLength(1);

    // Permanent rejection (550) is not retried.
    const other = await uploadSession(s);
    s.mail.failWith = Object.assign(new Error("mailbox unavailable"), { responseCode: 550 });
    await s.agent.post(`/api/sessions/${other.id}/email`).set(auth).send({ email: "gone@example.com" }).expect(202);
    await s.ctx.email.processDue();
    row = s.ctx.db.prepare(`SELECT * FROM emails WHERE masked = 'g***@example.com'`).get() as typeof row;
    expect(row.status).toBe("failed");
  });

  it("survives a restart with emails still queued", async () => {
    let s = startServer();
    const id = newSessionId();
    const [img] = await photos(1);
    await s.agent.post("/api/sessions").set(auth).send({ id, eventId: "mail", photoCount: 1 }).expect(201);
    await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "later@example.com" }).expect(202);
    // Simulate a crash in the middle of sending.
    s.ctx.db.prepare(`UPDATE emails SET status = 'sending'`).run();
    s = s.restart();
    await s.agent.post(`/api/sessions/${id}/photos?index=0`).set(auth).set("Content-Type", "image/jpeg").send(img).expect(201);
    await s.agent.post(`/api/sessions/${id}/complete`).set(auth).send({}).expect(200);
    await s.ctx.email.processDue();
    expect(s.mail.sent.map((m) => m.to)).toEqual(["later@example.com"]);
  });

  it("is disabled gracefully without SMTP configuration", async () => {
    const s = startServer(undefined, { SMTP_HOST: "" });
    const { id } = await uploadSession(s);
    expect((await s.agent.get("/api/config").expect(200)).body.emailEnabled).toBe(false);
    const r = await s.agent.post(`/api/sessions/${id}/email`).set(auth).send({ email: "a@example.com" }).expect(503);
    expect(r.body.error).toBe("email_disabled");
    await s.agent.get(`/api/sessions/${id}`).expect(200); // galleries still work
  });

  it("escapes event names in the HTML email", () => {
    const m = renderGalleryEmail(`<script>x</script> & "Co"`, "https://x.test/s/abc");
    expect(m.html).not.toContain("<script>");
    expect(m.html).toContain("&lt;script&gt;");
    expect(m.text).toContain("https://x.test/s/abc");
  });
});
