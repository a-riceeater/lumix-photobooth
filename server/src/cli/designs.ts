/**
 * Design template tool.
 *
 *   npm run designs -- validate [design-id-or-folder ...]
 *   npm run designs -- preview <design-id-or-folder> [--photos a.jpg b.jpg ...] [--out file.jpg] [--full]
 *   npm run designs -- write-previews [design-id ...]     (re-creates preview.png thumbnails)
 *   npm run designs -- new <new-id> [--from classic-white]
 *
 * DESIGNS_DIR from server/.env is used (default ../designs).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadDotenv } from "dotenv";
import sharp from "sharp";
import { loadDesign, type Design } from "../designs.js";
import { isDesignId } from "../ids.js";
import { previewScale, renderDesign } from "../render.js";
import { samplePhoto } from "../samples.js";

const SERVER_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
loadDotenv({ path: path.join(SERVER_DIR, ".env"), quiet: true });
const DESIGNS_DIR = path.resolve(SERVER_DIR, process.env.DESIGNS_DIR || "../designs");

function folderFor(arg: string): string {
  return fs.existsSync(path.join(arg, "design.json")) ? path.resolve(arg) : path.join(DESIGNS_DIR, arg);
}

function allFolders(): string[] {
  return fs.readdirSync(DESIGNS_DIR, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith(".") && !e.name.startsWith("_"))
    .map((e) => path.join(DESIGNS_DIR, e.name))
    .filter((d) => fs.existsSync(path.join(d, "design.json")));
}

function validate(args: string[]): number {
  const folders = args.length ? args.map(folderFor) : allFolders();
  let bad = 0;
  for (const dir of folders) {
    const { design, errors, warnings } = loadDesign(dir);
    const name = path.basename(dir);
    if (design) {
      console.log(`✔ ${name}: ${design.name} — ${design.width}×${design.height}, ${design.photoCount} photos, ${design.photos.length} slots`);
    } else {
      bad++;
      console.log(`✘ ${name}`);
    }
    for (const e of errors) console.log(`    error:   ${e}`);
    for (const w of warnings) console.log(`    warning: ${w}`);
  }
  console.log(`\n${folders.length - bad} valid, ${bad} invalid (${DESIGNS_DIR})`);
  return bad ? 1 : 0;
}

function requireDesign(arg: string | undefined): Design {
  if (!arg) throw new Error("Give a design id or folder");
  const { design, errors } = loadDesign(folderFor(arg));
  if (!design) throw new Error(`Design is invalid:\n  ${errors.join("\n  ")}`);
  return design;
}

async function photosFor(design: Design, given: string[]): Promise<(string | Buffer)[]> {
  if (given.length) {
    if (given.length < design.photoCount) throw new Error(`${design.id} needs ${design.photoCount} photos, got ${given.length}`);
    return given.map((p) => path.resolve(p));
  }
  return Promise.all(Array.from({ length: design.photoCount }, (_, i) => samplePhoto(i, 1800, 1200)));
}

async function preview(args: string[]): Promise<number> {
  const opts = parseFlags(args);
  const design = requireDesign(opts.positional[0]);
  const photos = await photosFor(design, opts.list("photos"));
  const full = opts.has("full");
  const out = path.resolve(opts.value("out") ?? path.join(design.dir, "out", `${design.id}-${full ? "full" : "preview"}.jpg`));
  const t0 = Date.now();
  const jpeg = await renderDesign(design, photos, { scale: full ? 1 : previewScale(design), eventName: "Sample Event" });
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, jpeg);
  const meta = await sharp(jpeg).metadata();
  console.log(`Rendered ${design.id} (${meta.width}×${meta.height}) in ${Date.now() - t0} ms → ${out}`);
  return 0;
}

/** preview.png = a ~600 px render with numbered sample photos. */
export async function writePreview(design: Design): Promise<string> {
  const photos = await photosFor(design, []);
  const jpeg = await renderDesign(design, photos, { scale: previewScale(design, 600), eventName: "Event Name" });
  const out = path.join(design.dir, "preview.png");
  await sharp(jpeg).png({ compressionLevel: 9, palette: true, quality: 90 }).toFile(out);
  return out;
}

async function writePreviews(args: string[]): Promise<number> {
  const folders = args.length ? args.map(folderFor) : allFolders();
  for (const dir of folders) {
    const d = requireDesign(dir);
    console.log(`preview.png for ${d.id} → ${await writePreview(d)}`);
  }
  return 0;
}

function create(args: string[]): number {
  const opts = parseFlags(args);
  const id = opts.positional[0];
  if (!isDesignId(id)) throw new Error("New design id must be lowercase letters, digits and dashes");
  const from = folderFor(opts.value("from") ?? "classic-white");
  const dest = path.join(DESIGNS_DIR, id);
  if (fs.existsSync(dest)) throw new Error(`${dest} already exists`);
  fs.cpSync(from, dest, { recursive: true, filter: (src) => !src.includes(`${path.sep}out`) });
  const json = JSON.parse(fs.readFileSync(path.join(dest, "design.json"), "utf8"));
  json.id = id;
  json.name = `${json.name} (copy)`;
  json.version = 1;
  fs.writeFileSync(path.join(dest, "design.json"), JSON.stringify(json, null, 2) + "\n");
  console.log(`Created ${dest} from ${path.basename(from)}. Edit design.json and the PNGs, then run:\n  npm run designs -- validate ${id}`);
  return 0;
}

function parseFlags(args: string[]) {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  let current: string | null = null;
  for (const a of args) {
    if (a.startsWith("--")) {
      current = a.slice(2);
      flags.set(current, []);
    } else if (current) flags.get(current)!.push(a);
    else positional.push(a);
  }
  return {
    positional,
    has: (k: string) => flags.has(k),
    value: (k: string) => flags.get(k)?.[0],
    list: (k: string) => flags.get(k) ?? [],
  };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const [cmd, ...rest] = process.argv.slice(2);
  const run: Record<string, (a: string[]) => number | Promise<number>> = { validate, preview, "write-previews": writePreviews, new: create };
  if (!cmd || !run[cmd]) {
    console.log("usage: npm run designs -- <validate|preview|write-previews|new> [...]\nSee the header of src/cli/designs.ts.");
    process.exit(cmd ? 1 : 0);
  }
  Promise.resolve()
    .then(() => run[cmd](rest))
    .then((code) => process.exit(code))
    .catch((e) => {
      console.error((e as Error).message);
      process.exit(1);
    });
}
