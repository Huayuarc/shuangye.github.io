// node render.mjs <fig dir> <out html>: the first frame on the first page, as HTML.
import { readFig } from "./fig.mjs";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "fs";
import { relative, dirname, resolve } from "path";
const [dir, outPath] = process.argv.slice(2);
const { message } = readFig(readFileSync(`${dir}/canvas.fig`));
const id = g => `${g.sessionID}:${g.localID}`, hex = a => Buffer.from(a).toString("hex");
const nodes = message.nodeChanges;
const children = p => nodes.filter(n => n.parentIndex && id(n.parentIndex.guid) === p)
  .sort((a, b) => a.parentIndex.position < b.parentIndex.position ? -1 : 1);
const page = nodes.find(n => n.type === "CANVAS" && !n.name.includes("Internal"));
const frame = children(id(page.guid)).find(n => n.type === "FRAME");
const rgba = (c, o = 1) => `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${(c.a * o).toFixed(4)})`;
const imageDir = `${dirname(resolve(outPath))}/images`;
rmSync(imageDir, { recursive: true, force: true }); mkdirSync(imageDir, { recursive: true });
// WebKit will not take a local file with no extension for an image.
const imgURL = h => {
  const bytes = readFileSync(`${dir}/images/${h}`);
  const ext = bytes[0] === 0x89 ? "png" : bytes[0] === 0xff ? "jpg" : "bin";
  writeFileSync(`${imageDir}/${h}.${ext}`, bytes);
  return `images/${h}.${ext}`;
};
const fills = n => (n.fillPaints ?? []).filter(p => p.visible !== false).map(p =>
  p.type === "SOLID" ? `linear-gradient(${rgba(p.color, p.opacity ?? 1)},${rgba(p.color, p.opacity ?? 1)})`
  : p.type === "IMAGE" ? `url('${imgURL(hex(p.image.hash))}') center / ${p.imageScaleMode === "FIT" ? "contain" : "cover"} no-repeat` : null)
  .filter(Boolean).reverse().join(", ");   // CSS paints the first layer on top; Figma the last
const shadows = n => (n.effects ?? []).filter(e => e.visible !== false && e.type === "DROP_SHADOW")
  .map(e => `${e.offset.x}px ${e.offset.y}px ${e.radius}px ${e.spread ?? 0}px ${rgba(e.color)}`);
const stroke = n => {
  const p = (n.strokePaints ?? []).find(p => p.visible !== false && p.type === "SOLID");
  if (!p || !n.strokeWeight) return "";
  const inset = n.strokeAlign === "INSIDE" ? "inset " : "";
  return `<i style="position:absolute;inset:0;border-radius:inherit;box-shadow:${inset}0 0 0 ${n.strokeWeight}px ${rgba(p.color, p.opacity ?? 1)}"></i>`;
};
const el = n => {
  const t = n.transform;
  const style = [`position:absolute`, `left:0`, `top:0`, `width:${n.size.x}px`, `height:${n.size.y}px`,
    `transform-origin:0 0`, `transform:matrix(${t.m00},${t.m10},${t.m01},${t.m11},${t.m02},${t.m12})`,
    n.cornerRadius ? `border-radius:${n.cornerRadius}px` : "", `background:${fills(n) || "transparent"}`,
    shadows(n).length ? `box-shadow:${shadows(n).join(",")}` : "", n.opacity != null && n.opacity !== 1 ? `opacity:${n.opacity}` : ""].filter(Boolean).join(";");
  return `<div title="${n.name}" style="${style}">${stroke(n)}${children(id(n.guid)).map(el).join("")}</div>`;
};
const W = frame.size.x, H = frame.size.y;
writeFileSync(outPath, `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;width:${W}px;height:${H}px;overflow:hidden}</style></head><body>
<div style="position:relative;width:${W}px;height:${H}px;overflow:${frame.frameMaskDisabled ? "visible" : "hidden"};background:${fills(frame)}">${children(id(frame.guid)).map(el).join("")}</div></body></html>`);
// The frame's size, for snapshot.
console.log(`${W} ${H}`);
