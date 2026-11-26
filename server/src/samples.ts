import sharp from "sharp";

const PALETTES = [
  ["#f97316", "#fde68a", "#7c2d12"],
  ["#0ea5e9", "#a7f3d0", "#1e3a8a"],
  ["#d946ef", "#fbcfe8", "#4c1d95"],
  ["#22c55e", "#fef9c3", "#14532d"],
  ["#ef4444", "#fecaca", "#450a0a"],
  ["#6366f1", "#e0e7ff", "#1e1b4b"],
];

/**
 * A synthetic, colourful 3:2 "photo" (JPEG) so the whole system can be
 * exercised without a camera. Deterministic for a given seed.
 */
export async function samplePhoto(seed: number, width = 3000, height = 2000, label?: string): Promise<Buffer> {
  const [a, b, c] = PALETTES[Math.abs(seed) % PALETTES.length];
  let x = (seed + 1) * 9301;
  const rand = () => {
    x = (x * 9301 + 49297) % 233280;
    return x / 233280;
  };
  const circles = Array.from({ length: 7 }, () => {
    const r = (0.08 + rand() * 0.18) * height;
    return `<circle cx="${rand() * width}" cy="${rand() * height}" r="${r}" fill="${rand() > 0.5 ? b : c}" fill-opacity="${0.25 + rand() * 0.4}"/>`;
  }).join("");
  const text = label ?? String(seed + 1);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${c}"/></linearGradient></defs>
    <rect width="100%" height="100%" fill="url(#g)"/>${circles}
    <rect x="${width * 0.04}" y="${height * 0.06}" width="${width * 0.92}" height="${height * 0.88}" fill="none" stroke="#ffffff" stroke-opacity="0.5" stroke-width="${height * 0.006}"/>
    <text x="50%" y="58%" text-anchor="middle" font-family="Helvetica, Arial, sans-serif" font-weight="bold" font-size="${height * 0.32}" fill="#ffffff" fill-opacity="0.9">${text}</text>
  </svg>`;
  return sharp(Buffer.from(svg)).jpeg({ quality: 88 }).toBuffer();
}
