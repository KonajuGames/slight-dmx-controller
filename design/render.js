// Rasterises the chosen SVG sources to the PNGs the game uses.
//   cd design && npm i sharp@0.32.6 && node render.js
// Outputs ../icon.png (512) and ../splash.png (2048x1024).
const sharp = require("sharp");
const fs = require("fs");

async function png(src, w, h, out) {
  await sharp(fs.readFileSync(src), { density: 384 })
    .resize(w, h, { fit: "fill" })
    .png()
    .toFile(out);
  console.log(out, w + "x" + h);
}

(async () => {
  await png("icon_c_spectrum.svg", 512, 512, "../icon.png");
  await png("splash_2_rig.svg", 2048, 1024, "../splash.png");
})();
