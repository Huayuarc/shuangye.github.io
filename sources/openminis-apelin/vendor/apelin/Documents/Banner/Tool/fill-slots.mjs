// node fill-slots.mjs <template.fig> <out.fig> <work dir> <icon> <screenshot 1> … <screenshot n>
//
// Puts each image into the template's slot of its name: `Icon`, and
// `Screenshot <n>` for the n-th screenshot (a slot can appear more than once).
// The template keeps its layout; only the image fills and their thumbnails
// change. Leaves the unpacked result in <work dir> for render.mjs.
import { readFig, writeFig } from "./fig.mjs";
import { readFileSync, writeFileSync, mkdirSync, rmSync, copyFileSync, existsSync } from "fs";
import { createHash } from "crypto";
import { execFileSync } from "child_process";
import { resolve } from "path";

const [template, out, work, icon, ...screenshots] = process.argv.slice(2).map(p => resolve(p));
rmSync(work, { recursive: true, force: true });
mkdirSync(`${work}/source`, { recursive: true });
mkdirSync(`${work}/fig/images`, { recursive: true });
execFileSync("unzip", ["-q", template, "-d", `${work}/source`]);

const fig = readFig(readFileSync(`${work}/source/canvas.fig`));
const hex = bytes => Buffer.from(bytes).toString("hex");
const sha1 = bytes => createHash("sha1").update(bytes).digest("hex");
const pixels = path => execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", path])
    .toString().match(/pixel\w+: (\d+)/g).map(line => Number(line.split(": ")[1]));

/// An image and its thumbnail, `thumbnailWidth` wide, stored under their SHA-1 as Figma names them.
const stored = new Map();
function store(path, thumbnailWidth) {
    const key = `${path}@${thumbnailWidth}`;
    if (stored.has(key)) return stored.get(key);
    const bytes = readFileSync(path);
    const [width, height] = pixels(path);
    const hash = sha1(bytes);
    writeFileSync(`${work}/fig/images/${hash}`, bytes);
    const thumbnailPath = `${work}/thumbnail.${path.endsWith(".png") ? "png" : "jpg"}`;
    execFileSync("sips", ["-Z", String(Math.round(thumbnailWidth * Math.max(width, height) / width)), path, "--out", thumbnailPath]);
    const thumbnail = readFileSync(thumbnailPath);
    rmSync(thumbnailPath);
    writeFileSync(`${work}/fig/images/${sha1(thumbnail)}`, thumbnail);
    const image = { hash, thumbnail: sha1(thumbnail), width, height };
    stored.set(key, image);
    return image;
}

const keep = hash => copyFileSync(`${work}/source/images/${hash}`, `${work}/fig/images/${hash}`);
const filled = new Set();
for (const node of fig.message.nodeChanges) {
    for (const paint of node.fillPaints ?? []) {
        if (paint.type !== "IMAGE" || !paint.image?.hash) continue;
        const slot = node.name === "Icon" ? 0 : Number(node.name.match(/^Screenshot (\d+)$/)?.[1]);
        const path = slot === 0 ? icon : screenshots[slot - 1];
        if (!path) {
            keep(hex(paint.image.hash));
            if (paint.imageThumbnail) keep(hex(paint.imageThumbnail.hash));
            continue;
        }
        const thumbnailWidth = paint.imageThumbnail
            ? pixels(`${work}/source/images/${hex(paint.imageThumbnail.hash)}`)[0] : 230;
        const image = store(path, thumbnailWidth);
        paint.image.hash = Buffer.from(image.hash, "hex");
        if (paint.imageThumbnail) paint.imageThumbnail.hash = Buffer.from(image.thumbnail, "hex");
        paint.originalImageWidth = image.width;
        paint.originalImageHeight = image.height;
        // The template's crop and blurred placeholder were for its own image.
        paint.transform = { m00: 1, m01: 0, m02: 0, m10: 0, m11: 1, m12: 0 };
        delete paint.thumbHash;
        filled.add(node.name);
    }
}
const expected = ["Icon", ...screenshots.map((_, index) => `Screenshot ${index + 1}`)];
const missing = expected.filter(name => !filled.has(name));
if (missing.length) throw new Error(`the template has no slot named ${missing.join(", ")}`);

writeFileSync(`${work}/fig/canvas.fig`, writeFig(fig));
copyFileSync(`${work}/source/meta.json`, `${work}/fig/meta.json`);
if (existsSync(`${work}/source/thumbnail.png`)) copyFileSync(`${work}/source/thumbnail.png`, `${work}/fig/thumbnail.png`);
console.log(`filled ${[...filled].sort().join(", ")}`);
