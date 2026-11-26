/**
 * Regenerates the example designs in ../designs (PNG assets, design.json,
 * preview.png). Run with: npx tsx scripts/generate-example-designs.ts
 * Real event designs are normally drawn in Photoshop/Affinity/Canva instead;
 * this only exists so the examples are reproducible.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { writePreview } from "../src/cli/designs.js";
import { loadDesign } from "../src/designs.js";

const OUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "designs");

const png = (svg: string, file: string) => sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(file);
const svg = (w: number, h: number, body: string) => `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">${body}</svg>`;

interface Spec {
  json: Record<string, unknown>;
  background?: string;
  foreground?: string;
}

const slots3 = (x: number, y0: number, w: number, h: number, gap: number, extra: Record<string, unknown> = {}) =>
  [0, 1, 2].map((i) => ({ index: i, x, y: y0 + i * (h + gap), width: w, height: h, fit: "cover", ...extra }));

const specs: Spec[] = [
  {
    json: {
      id: "classic-white", name: "Classic White", version: 1,
      description: "Traditional 2×6 strip: three photos on white with the event name underneath.",
      width: 1200, height: 3600, photoCount: 3,
      background: "background.png", foreground: null, preview: "preview.png",
      photos: slots3(60, 60, 1080, 720, 60),
      texts: [
        { text: "{eventName}", x: 60, y: 2620, width: 1080, align: "center", fontSize: 92, fontWeight: "bold", color: "#18181b", fontFamily: "Georgia, serif" },
        { text: "{date}", x: 60, y: 2760, width: 1080, align: "center", fontSize: 56, color: "#71717a", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1200, 3600, `<rect width="100%" height="100%" fill="#ffffff"/><rect x="24" y="24" width="1152" height="3552" fill="none" stroke="#e4e4e7" stroke-width="4"/>
      <line x1="420" y1="2860" x2="780" y2="2860" stroke="#d4d4d8" stroke-width="4"/>`),
  },
  {
    json: {
      id: "midnight-film", name: "Midnight Film", version: 1,
      description: "Black film strip with sprocket holes overlapping the photos (foreground overlay).",
      width: 1200, height: 3600, photoCount: 3,
      background: "background.png", foreground: "foreground.png", preview: "preview.png",
      backgroundColor: "#0a0a0a",
      photos: slots3(130, 200, 940, 627, 120, { radius: 12 }),
      texts: [
        { text: "{eventName}", x: 0, y: 2700, width: 1200, align: "center", fontSize: 84, fontWeight: "bold", color: "#fafafa", fontFamily: "Helvetica, Arial, sans-serif" },
        { text: "{date}", x: 0, y: 2820, width: 1200, align: "center", fontSize: 48, color: "#a1a1aa", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1200, 3600, `<rect width="100%" height="100%" fill="#0a0a0a"/>`),
    // Sprocket holes on both edges; transparent elsewhere so photos show through.
    foreground: svg(1200, 3600, Array.from({ length: 36 }, (_, i) => {
      const y = 30 + i * 100;
      return `<rect x="28" y="${y}" width="64" height="44" rx="8" fill="#f5f5f4"/><rect x="1108" y="${y}" width="64" height="44" rx="8" fill="#f5f5f4"/>`;
    }).join("") + `<rect x="110" y="0" width="6" height="3600" fill="#27272a"/><rect x="1084" y="0" width="6" height="3600" fill="#27272a"/>`),
  },
  {
    json: {
      id: "story-polaroid", name: "Story Polaroids", version: 1,
      description: "9:16 social story with three tilted instant-film photos.",
      width: 1080, height: 1920, photoCount: 3,
      background: "background.png", foreground: null, preview: "preview.png",
      photos: [
        { index: 0, x: 120, y: 210, width: 780, height: 520, fit: "cover", rotation: -4, radius: 6 },
        { index: 1, x: 180, y: 760, width: 780, height: 520, fit: "cover", rotation: 3, radius: 6 },
        { index: 2, x: 130, y: 1310, width: 780, height: 520, fit: "cover", rotation: -2, radius: 6 },
      ],
      texts: [
        { text: "{eventName}", x: 0, y: 140, width: 1080, align: "center", fontSize: 72, fontWeight: "bold", color: "#3b0764", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1080, 1920, `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fdf2f8"/><stop offset="1" stop-color="#ede9fe"/></linearGradient></defs>
      <rect width="100%" height="100%" fill="url(#g)"/>
      <rect x="96" y="186" width="828" height="568" fill="#fff" transform="rotate(-4 510 470)"/>
      <rect x="156" y="736" width="828" height="568" fill="#fff" transform="rotate(3 570 1020)"/>
      <rect x="106" y="1286" width="828" height="568" fill="#fff" transform="rotate(-2 520 1570)"/>`),
  },
  {
    json: {
      id: "square-trio", name: "Square Trio", version: 1,
      description: "Square collage: one large photo and two smaller ones.",
      width: 2048, height: 2048, photoCount: 3,
      background: "background.png", foreground: null, preview: "preview.png",
      backgroundColor: "#f5f5f4",
      photos: [
        { index: 0, x: 64, y: 64, width: 1920, height: 1080, fit: "cover", radius: 24 },
        { index: 1, x: 64, y: 1184, width: 940, height: 627, fit: "cover", radius: 24 },
        { index: 2, x: 1044, y: 1184, width: 940, height: 627, fit: "cover", radius: 24 },
      ],
      texts: [
        { text: "{eventName} · {date}", x: 64, y: 1930, width: 1920, align: "center", fontSize: 64, color: "#44403c", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(2048, 2048, `<rect width="100%" height="100%" fill="#f5f5f4"/>`),
  },
  {
    json: {
      id: "postcard-4x6", name: "Postcard 4×6", version: 1,
      description: "Printable 6×4 inch landscape layout at 300 dpi.",
      width: 1800, height: 1200, photoCount: 3,
      background: "background.png", foreground: null, preview: "preview.png",
      photos: [
        { index: 0, x: 50, y: 50, width: 1110, height: 740, fit: "cover" },
        { index: 1, x: 1200, y: 50, width: 550, height: 367, fit: "cover" },
        { index: 2, x: 1200, y: 423, width: 550, height: 367, fit: "cover" },
      ],
      texts: [
        { text: "{eventName}", x: 50, y: 960, width: 1700, align: "center", fontSize: 96, fontWeight: "bold", color: "#1e3a8a", fontFamily: "Georgia, serif" },
        { text: "{date}", x: 50, y: 1070, width: 1700, align: "center", fontSize: 48, color: "#64748b", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1800, 1200, `<rect width="100%" height="100%" fill="#f8fafc"/><rect x="50" y="850" width="1700" height="4" fill="#cbd5e1"/>`),
  },
  {
    json: {
      id: "grid-four", name: "Four Grid", version: 1,
      description: "2×2 grid for four-photo sessions (hidden for three-photo sessions).",
      width: 1800, height: 1200, photoCount: 4,
      background: null, foreground: null, preview: "preview.png",
      backgroundColor: "#ffffff",
      photos: [0, 1, 2, 3].map((i) => ({ index: i, x: 30 + (i % 2) * 885, y: 30 + Math.floor(i / 2) * 585, width: 855, height: 555, fit: "cover", radius: 10 })),
    },
  },
];

/** White instant-film frames behind rotated photo slots (border px around each slot). */
const polaroidFrames = (slots: { x: number; y: number; width: number; height: number; rotation: number }[], border = 24) =>
  slots.map((p) => {
    const cx = p.x + p.width / 2, cy = p.y + p.height / 2;
    return `<rect x="${p.x - border}" y="${p.y - border}" width="${p.width + 2 * border}" height="${p.height + 2 * border}" fill="#fff" transform="rotate(${p.rotation} ${cx} ${cy})"/>`;
  }).join("");

const storySlots4 = [
  { index: 0, x: 150, y: 230, width: 600, height: 400, fit: "cover", rotation: -4, radius: 6 },
  { index: 1, x: 330, y: 640, width: 600, height: 400, fit: "cover", rotation: 3, radius: 6 },
  { index: 2, x: 150, y: 1050, width: 600, height: 400, fit: "cover", rotation: -3, radius: 6 },
  { index: 3, x: 330, y: 1460, width: 600, height: 400, fit: "cover", rotation: 2, radius: 6 },
];

const slots4 = (x: number, y0: number, w: number, h: number, gap: number, extra: Record<string, unknown> = {}) =>
  [0, 1, 2, 3].map((i) => ({ index: i, x, y: y0 + i * (h + gap), width: w, height: h, fit: "cover", ...extra }));

// 4-photo versions of the 3-photo designs (same look, so every style is
// available whichever photo count the booth uses).
specs.push(
  {
    json: {
      id: "classic-white-4", name: "Classic White", version: 1,
      description: "Traditional 2×6 strip: four photos on white with the event name underneath.",
      width: 1200, height: 3600, photoCount: 4,
      background: "background.png", foreground: null, preview: "preview.png",
      photos: slots4(90, 60, 1020, 680, 50),
      texts: [
        { text: "{eventName}", x: 60, y: 3190, width: 1080, align: "center", fontSize: 92, fontWeight: "bold", color: "#18181b", fontFamily: "Georgia, serif" },
        { text: "{date}", x: 60, y: 3320, width: 1080, align: "center", fontSize: 56, color: "#71717a", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1200, 3600, `<rect width="100%" height="100%" fill="#ffffff"/><rect x="24" y="24" width="1152" height="3552" fill="none" stroke="#e4e4e7" stroke-width="4"/>
      <line x1="420" y1="3410" x2="780" y2="3410" stroke="#d4d4d8" stroke-width="4"/>`),
  },
  {
    json: {
      id: "midnight-film-4", name: "Midnight Film", version: 1,
      description: "Black film strip with four photos and sprocket holes overlapping them (foreground overlay).",
      width: 1200, height: 3600, photoCount: 4,
      background: "background.png", foreground: "foreground.png", preview: "preview.png",
      backgroundColor: "#0a0a0a",
      photos: slots4(150, 160, 900, 600, 80, { radius: 12 }),
      texts: [
        { text: "{eventName}", x: 0, y: 3100, width: 1200, align: "center", fontSize: 84, fontWeight: "bold", color: "#fafafa", fontFamily: "Helvetica, Arial, sans-serif" },
        { text: "{date}", x: 0, y: 3220, width: 1200, align: "center", fontSize: 48, color: "#a1a1aa", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: specs.find((s) => s.json.id === "midnight-film")!.background,
    foreground: specs.find((s) => s.json.id === "midnight-film")!.foreground,
  },
  {
    json: {
      id: "story-polaroid-4", name: "Story Polaroids", version: 1,
      description: "9:16 social story with four tilted instant-film photos.",
      width: 1080, height: 1920, photoCount: 4,
      background: "background.png", foreground: null, preview: "preview.png",
      photos: storySlots4,
      texts: [
        { text: "{eventName}", x: 0, y: 150, width: 1080, align: "center", fontSize: 72, fontWeight: "bold", color: "#3b0764", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1080, 1920, `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fdf2f8"/><stop offset="1" stop-color="#ede9fe"/></linearGradient></defs>
      <rect width="100%" height="100%" fill="url(#g)"/>${polaroidFrames(storySlots4, 20)}`),
  },
  {
    json: {
      id: "square-quad", name: "Square Collage", version: 1,
      description: "Square collage: one large photo and three smaller ones.",
      width: 2048, height: 2048, photoCount: 4,
      background: "background.png", foreground: null, preview: "preview.png",
      backgroundColor: "#f5f5f4",
      photos: [
        { index: 0, x: 64, y: 64, width: 1920, height: 1080, fit: "cover", radius: 24 },
        { index: 1, x: 64, y: 1184, width: 613, height: 409, fit: "cover", radius: 20 },
        { index: 2, x: 717, y: 1184, width: 613, height: 409, fit: "cover", radius: 20 },
        { index: 3, x: 1370, y: 1184, width: 613, height: 409, fit: "cover", radius: 20 },
      ],
      texts: [
        { text: "{eventName}", x: 64, y: 1800, width: 1920, align: "center", fontSize: 96, fontWeight: "bold", color: "#292524", fontFamily: "Helvetica, Arial, sans-serif" },
        { text: "{date}", x: 64, y: 1910, width: 1920, align: "center", fontSize: 56, color: "#78716c", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(2048, 2048, `<rect width="100%" height="100%" fill="#f5f5f4"/>`),
  },
  {
    json: {
      id: "postcard-four", name: "Postcard 4×6", version: 1,
      description: "Printable 6×4 inch landscape layout at 300 dpi with four photos.",
      width: 1800, height: 1200, photoCount: 4,
      background: "background.png", foreground: null, preview: "preview.png",
      photos: [
        { index: 0, x: 320, y: 40, width: 560, height: 373, fit: "cover" },
        { index: 1, x: 920, y: 40, width: 560, height: 373, fit: "cover" },
        { index: 2, x: 320, y: 453, width: 560, height: 373, fit: "cover" },
        { index: 3, x: 920, y: 453, width: 560, height: 373, fit: "cover" },
      ],
      texts: [
        { text: "{eventName}", x: 50, y: 980, width: 1700, align: "center", fontSize: 96, fontWeight: "bold", color: "#1e3a8a", fontFamily: "Georgia, serif" },
        { text: "{date}", x: 50, y: 1090, width: 1700, align: "center", fontSize: 48, color: "#64748b", fontFamily: "Helvetica, Arial, sans-serif" },
      ],
    },
    background: svg(1800, 1200, `<rect width="100%" height="100%" fill="#f8fafc"/><rect x="50" y="866" width="1700" height="4" fill="#cbd5e1"/>`),
  },
);

for (const spec of specs) {
  const dir = path.join(OUT, spec.json.id as string);
  fs.mkdirSync(dir, { recursive: true });
  if (spec.background) await png(spec.background, path.join(dir, "background.png"));
  if (spec.foreground) await png(spec.foreground, path.join(dir, "foreground.png"));
  // preview.png is written below; validation needs the file to exist first.
  fs.writeFileSync(path.join(dir, "design.json"), JSON.stringify({ ...spec.json, preview: null }, null, 2) + "\n");
  const { design, errors } = loadDesign(dir);
  if (!design) throw new Error(`${spec.json.id}: ${errors.join("; ")}`);
  await writePreview(design);
  fs.writeFileSync(path.join(dir, "design.json"), JSON.stringify(spec.json, null, 2) + "\n");
  console.log(`generated ${dir}`);
}
