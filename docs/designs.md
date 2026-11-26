# Photo strip designs

A design is a folder in `designs/` (or wherever `DESIGNS_DIR` points) containing a `design.json` and PNG
artwork. Adding a folder is enough to register it: the server rescans every 10 seconds, or immediately via
**Admin ▸ Reload designs**, `sudo systemctl reload photobooth` (SIGHUP) or a restart. No code changes.

```text
designs/
  classic-white/
    design.json
    background.png      optional (else backgroundColor)
    foreground.png      optional, transparent overlay drawn on top of the photos
    preview.png         optional thumbnail for the design picker
```

Folders starting with `_` or `.` are ignored (handy for drafts).

## Making a theme in the admin page (no files to edit)

*Admin ▸ Themes ▸ New single-column theme* builds a design for you:

* **Canvas** — 2×6 strip, 4×6 portrait, 9:16 story or a custom size, plus a background colour.
* **Background image** — any PNG/JPEG/WebP; it is cropped to fill the canvas (never stretched). The original
  upload is kept as `background-source.png`, so changing the canvas later re-crops it cleanly.
* **Overlay** — an optional transparent PNG drawn on top of the photos (frames, stickers, logos).
* **Photos** — how many (1–8), outer margin, gap, rounded corners, an optional **top margin** (distance from
  the top to the first photo; empty = the photos are centred), and the shape: *Keep 3:2* (whole photo, the
  column shrinks to fit) or *Fill the column* (photos stretch to the available height and are cropped).
* **Text** — a *Show text* switch (off = no text and no text area), title and subtitle (`{eventName}`, `{date}`, `{time}` are filled in), above or below the photos or
  none, the height of the text area, font, sizes and colours.

A preview with sample photos updates as you type. *Save theme* writes a normal design folder
(`designs/<theme-id>/design.json` + PNGs + `preview.png`); the builder settings are stored in `design.json`
under `"builder"`, so *Edit* reopens them. Saving an edit bumps `version` (so cached strips re-render) and moves
the previous version to `designs/_trash/`. Every theme — built-in or made here — can be **hidden** (stays
installed, not offered to guests or the booth; stored as `"enabled": false`) or **deleted** (moved to
`designs/_trash/`, restorable by moving it back). Themes made by hand can be hidden or deleted but are edited in
their files.

The server needs write access to `DESIGNS_DIR` for this (see `docs/deployment.md`).

## Rendering order

1. `backgroundColor`, then `background.png` stretched to the canvas
2. the session photos, in slot order, each cropped/fitted into its slot
3. `foreground.png` stretched to the canvas (transparency lets frames, stickers and borders overlap photos)
4. text elements

Photos are resampled with Lanczos3 and their EXIF orientation is applied. Originals are never modified;
strips are separate files rendered on demand and cached (the cache key includes a fingerprint of
`design.json` and the PNGs, so editing a design automatically produces fresh strips). Gallery previews are
rendered at ≤1600 px from medium-size copies; the full-resolution file is rendered only when downloaded.

## design.json reference

```json
{
  "id": "classic-white",
  "name": "Classic White",
  "description": "Traditional 2×6 strip.",
  "version": 1,
  "width": 1200,
  "height": 3600,
  "photoCount": 3,
  "backgroundColor": "#ffffff",
  "background": "background.png",
  "foreground": null,
  "preview": "preview.png",
  "photos": [
    { "index": 0, "x": 60, "y": 60,   "width": 1080, "height": 720, "fit": "cover" },
    { "index": 1, "x": 60, "y": 840,  "width": 1080, "height": 720, "fit": "cover", "radius": 24 },
    { "index": 2, "x": 60, "y": 1620, "width": 1080, "height": 720, "fit": "contain", "rotation": -3 }
  ],
  "texts": [
    { "text": "{eventName}", "x": 60, "y": 2620, "width": 1080, "align": "center",
      "fontSize": 92, "fontWeight": "bold", "fontFamily": "Georgia, serif", "color": "#18181b" },
    { "text": "{date}", "x": 60, "y": 2760, "width": 1080, "align": "center", "fontSize": 56, "color": "#71717a" }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Lowercase letters, digits, dashes. **Must equal the folder name.** |
| `name`, `description` | name yes | Shown in the gallery design picker. |
| `version` | yes | Integer ≥ 1. Bump it when you change a design. |
| `width`, `height` | yes | Output canvas in pixels (100–12000). |
| `photoCount` | yes | Number of photos the design needs. Only sessions with exactly this many photos see the design. |
| `backgroundColor` | no | Hex colour (default `#ffffff`). |
| `background`, `foreground`, `preview` | no | PNG file names inside the folder, or `null`. |
| `photos[]` | yes | One or more slots. Every index `0 … photoCount-1` must appear at least once (an index may appear twice). |
| `photos[].x/y/width/height` | yes | Slot rectangle in canvas pixels (top-left origin). Slots may overhang the edge (clipped, warning). |
| `photos[].fit` | no | `cover` (default: fill the slot, crop the overflow, centred) or `contain` (whole photo, transparent bars). |
| `photos[].radius` | no | Rounded-corner radius in pixels. |
| `photos[].rotation` | no | Degrees clockwise around the slot centre. |
| `texts[]` | no | Text drawn last. `text` supports `{eventName}`, `{date}`, `{time}`. `y` is the text baseline. `align` is relative to the box `x … x+width`. Optional `rotation`. |

Fonts: text is rendered with the server's installed fonts (fontconfig). Use common families
(`Helvetica, Arial, sans-serif`, `Georgia, serif`, `DejaVu Sans`) or install the font on the server.
For guaranteed typography, put the text into `background.png`/`foreground.png` instead.

## Common formats

| Format | Canvas | Example design |
|---|---|---|
| Classic 2×6 strip (600 dpi) | 1200 × 3600 | `classic-white`, `midnight-film` |
| 9:16 social story | 1080 × 1920 | `story-polaroid` |
| Square collage | 2048 × 2048 | `square-trio` |
| Printable 4×6 / 6×4 at 300 dpi | 1800 × 1200 or 1200 × 1800 | `postcard-4x6` |
| 4-photo grid | 1800 × 1200 | `grid-four` (only for 4-photo sessions) |

The S5II shoots 3:2 photos (6000 × 4000). Slots with a 3:2 aspect (e.g. 1080 × 720) avoid cropping with `cover`.

## Making a design in Photoshop, Affinity Photo or Canva

1. **Create a canvas** at the final pixel size (e.g. 1200 × 3600 px). Work at 100 % size; dpi metadata does not matter.
2. **Draw the background layer** (colours, textures, logos, text that never changes).
3. **Mark the photo slots** with placeholder rectangles on their own layer. Read each rectangle's position and size:
   * Photoshop: select the layer, *Window ▸ Properties* shows X, Y, W, H in px (set *Units* to pixels).
   * Affinity Photo: the *Transform* panel (anchor at top-left).
   * Canva: select the element ▸ *Position* shows X/Y/width/height (use a custom-size design in px).
4. **Export `background.png`**: hide the placeholder layer and any overlay decorations; export the whole canvas as PNG.
5. **Optional overlay**: put decorations that should sit *on top of* photos (frames, stickers, film holes) on a layer
   with everything else transparent and export it as `foreground.png` (PNG with transparency; Canva needs
   *Transparent background*, a Pro feature — alternatively use Photoshop/Affinity/GIMP/Photopea).
6. **Write `design.json`** with the slot rectangles, or start from a copy:
   ```bash
   cd server
   npm run designs -- new my-wedding --from classic-white   # copies the folder and sets the id
   ```
7. **Validate and preview** with sample photos (or your own test shots):
   ```bash
   npm run designs -- validate my-wedding
   npm run designs -- preview my-wedding                     # → designs/my-wedding/out/my-wedding-preview.jpg
   npm run designs -- preview my-wedding --full --photos a.jpg b.jpg c.jpg --out /tmp/strip.jpg
   npm run designs -- write-previews my-wedding              # (re)creates preview.png
   ```
8. **Distribute** by copying the folder (zip it) to another server's `designs/` directory.

Validation errors name the exact problem, e.g. `photos[1].index 5 is out of range for photoCount 3`,
`background: file "bg.png" not found in my-wedding/`, `id "wedding" must match the folder name "my-wedding"`.
Invalid designs are skipped (and listed on the admin page); the rest keep working.

## Choosing designs

* Guests choose any compatible design on their gallery page at any time; the strip re-renders on demand.
* The default is, in order: the design the booth sent for the session (operator setting *Default strip design*),
  the event's default (admin page), then the first compatible design alphabetically.
* `server/scripts/generate-example-designs.ts` regenerates the bundled examples (`npm run generate-designs`).
