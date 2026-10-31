/**
 * Regenerates every mark the site serves, from the repo-root `design/`.
 *
 * `design/drakar-icon.svg` is the one source: `make icon` in apps/apple builds the
 * app's icon from it, and this builds the site's. Nothing here transcribes a
 * coordinate. Cupertino once hand-copied its marks out of a design directory and
 * the site served an earlier direction of the mark than the app shipped. Run
 * `pnpm icons` after the icon changes rather than moving files.
 *
 * Armada's script, with Drakar's one difference: the icon is full-bleed and square
 * (Icon Composer applies the squircle in the app), so the web marks that are shown
 * as they are, the favicons, get the plate's corner here, while `app-icon.svg`
 * stays a byte-for-byte copy. That copy is what sibling sites compare their own
 * copies against (`sibling-stale` in the fleet survey), and every page rounds it
 * with CSS.
 *
 * Every output is committed, so a checkout builds without running this.
 */
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import sharp from "sharp";

import { SOCIAL_CARD } from "../src/config.ts";
import { composeCard } from "./social-card.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const pub = join(here, "..", "public");
const design = join(here, "..", "..", "..", "design");

/** Loud on a missing source: a silent skip here ships a stale mark. */
const source = async (name) => {
  try {
    return await readFile(join(design, name), "utf8");
  } catch {
    throw new Error(`design/${name} is missing; it is the source of every mark the site serves.`);
  }
};

/**
 * Throws rather than passing the artwork through unchanged, so a change to the
 * icon's structure surfaces here instead of silently producing a wrong mark.
 */
const replaceOnce = (text, find, replacement, what) => {
  if (!text.includes(find)) throw new Error(`${what}: expected to find ${find}`);
  return text.replace(find, replacement);
};

const png = async (svg, out, size) => {
  const buf = await sharp(Buffer.from(svg), { density: 400 }).resize(size, size).png().toBuffer();
  await writeFile(join(pub, out), buf);
  console.log(`  ${out}  ${size}×${size}`);
};

console.log("icons →");

const icon = await source("drakar-icon.svg");

// The plate's corner, 230/1024, for the marks shown as they are. The whole
// artwork goes inside one rounded clip: the icon's own `#clip` holds the glass
// only, and the plate rect is drawn outside it, so rounding that clip alone
// leaves a square plate.
const rounded = replaceOnce(
  replaceOnce(
    icon,
    "</defs>",
    '<clipPath id="web-corner"><rect width="1024" height="1024" rx="230"/></clipPath></defs><g clip-path="url(#web-corner)">',
    "web corner",
  ),
  "</svg>",
  "</g></svg>",
  "web corner close",
);

await writeFile(join(pub, "app-icon.svg"), icon);
await writeFile(join(pub, "favicon.svg"), rounded);
console.log("  app-icon.svg (as is), favicon.svg (rounded)  from design/");

await png(rounded, "favicon-32.png", 32);

// What <Logo> renders, nav to closing plate. Not the SVG: Drakar's glass is
// drawn in gradients and masks, about 130 KB of it, which is a lot to fetch for
// a 23px mark on every page. 192 covers the largest use (76px) at 2x.
await png(rounded, "logo.png", 192);

// iOS applies its own mask to the touch icon, so it gets the square plate: a
// rounded one would have its corners rounded twice and painted black.
await png(icon, "apple-touch-icon.png", 180);

// The Stripe product image, shown beside the line item on the hosted checkout.
// Stripe stores the URL and fetches it, so renaming or deleting this file breaks
// a page nothing in this repo builds. Rounded: Stripe rounds its container far
// less than the squircle does.
await png(rounded, "product-image.png", 512);

// The OG card: what a link to the site looks like on X, Slack and iMessage. The
// words come from src/config.ts, because they are a claim about the product.
//
// Rasterised at density 200 for clean edges, then resized back down to the
// 1200×630 Layout.astro declares from the same SOCIAL_CARD.
const card = composeCard(icon, SOCIAL_CARD);
await writeFile(
  join(pub, "og-image.png"),
  await sharp(Buffer.from(card), { density: 200 })
    .resize(SOCIAL_CARD.width, SOCIAL_CARD.height)
    .png({ palette: true })
    .toBuffer(),
);
console.log(`  og-image.png  ${SOCIAL_CARD.width}×${SOCIAL_CARD.height}`);
