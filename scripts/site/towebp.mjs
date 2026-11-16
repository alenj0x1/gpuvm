// node towebp.mjs <srcDir> <outDir> name1,name2,...
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
// Playwright from PLAYWRIGHT_PKG (a package.json whose node_modules has it) or from here; CHROME = an installed browser.
const { chromium } = createRequire(process.env.PLAYWRIGHT_PKG || path.resolve("package.json"))("playwright");
const [,, src, out, names] = process.argv;
const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined });
const page = await browser.newPage();
await page.setContent("<html><body></body></html>");
let total = 0;
for (const n of names.split(",")) for (const lang of ["es", "en"]) for (const mode of ["light", "dark"]) {
  const f = path.join(src, `${n}-${lang}-${mode}.png`);
  const b64 = fs.readFileSync(f).toString("base64");
  const data = await page.evaluate(async (b64) => {
    const img = new Image(); img.src = "data:image/png;base64," + b64; await img.decode();
    const w = 1600, h = Math.round(img.height * w / img.width);
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    const g = c.getContext("2d"); g.imageSmoothingQuality = "high"; g.drawImage(img, 0, 0, w, h);
    return c.toDataURL("image/webp", 0.84).split(",")[1];
  }, b64);
  const o = path.join(out, `${n}-${lang}-${mode}.webp`);
  fs.writeFileSync(o, Buffer.from(data, "base64"));
  total += fs.statSync(o).size;
}
console.log("done", Math.round(total / 1024), "KB");
await browser.close();
