/**
 * One social card per release, for the link to /changelog/<version>/.
 *
 *   pnpm cards           # render every card that is missing or stale
 *   pnpm cards --check   # fail if one is, without rendering anything
 *
 * A release gets a card when its CHANGELOG section opens with a summary, a
 * `**Title.** description` paragraph: see `Summary` in scripts/lib/changelog.mjs.
 * A release without one gets a page that falls back to the site card.
 *
 * ## Baked on a Mac, checked anywhere
 *
 * The PNG is rendered here and committed, for the reason og-image.png is (see
 * generate-icons.mjs): the title is set in whatever font the rendering machine
 * resolves, and a Linux machine would quietly swap SF Pro for something else. So
 * a check cannot render a card to compare it.
 *
 * What it can do is compose the SVG, which is text and needs no font, and hash
 * it. `src/data/release-cards.json` records the hash of the SVG each PNG was
 * rendered from, so `--check` catches a card that has fallen behind its title,
 * its date, the icon, or the palette and layout in social-card.mjs, on a machine
 * that could never render it. `make changelog` runs this at release time, which
 * is when a new summary appears, and `make changelog-check` runs `--check`.
 *
 * The manifest is also what tells the site a card exists: src/data/changelog.ts
 * points a release's og:image at its PNG only when the manifest names it, so a
 * page never links a picture that was never rendered.
 *
 * DIVERGES from armada, whose PNGs are LFS objects. Drakar keeps the site's
 * images as plain files (no LFS in this repo, and CI checks out without it), as
 * bastion and cupertino keep their cards; a card is about 25 KB.
 */
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { parse, plain } from "../../../scripts/lib/changelog.mjs";
import { SITE_DOMAIN } from "../src/config.ts";
import { composeReleaseCard, RELEASE_CARD } from "./social-card.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const out = join(here, "..", "public", "changelog");
const manifestPath = join(here, "..", "src", "data", "release-cards.json");
const check = process.argv.includes("--check");

/** What the card says after the date: the page it is a picture of. */
const FOOTER = `${SITE_DOMAIN}/changelog`;

const read = (path) => readFile(join(root, path), "utf8");

/** Loud on a missing source, as generate-icons.mjs is: a silent skip ships a stale card. */
const icon = await read("design/drakar-icon.svg");

const releases = parse(await read("CHANGELOG.md")).filter((r) => !r.unreleased && r.summary);

/** @type {Record<string, string>} */
const recorded = existsSync(manifestPath) ? JSON.parse(await readFile(manifestPath, "utf8")) : {};
/** @type {Record<string, string>} */
const manifest = {};
const stale = [];

for (const release of releases) {
  // Throws on a title that needs a third line, so a summary the test somehow
  // let through still stops here, before a card is baked with it.
  const svg = composeReleaseCard(icon, {
    version: release.version,
    date: release.date,
    title: plain(release.summary.title),
    footer: FOOTER,
  });
  const hash = createHash("sha256").update(svg).digest("hex");
  manifest[release.version] = hash;
  const png = join(out, `${release.version}.png`);
  if (recorded[release.version] === hash && existsSync(png)) continue;
  stale.push(release.version);
  if (check) continue;

  // Imported here rather than at the top so `--check`, which renders nothing,
  // does not load sharp's native binary.
  const { default: sharp } = await import("sharp");
  await mkdir(out, { recursive: true });
  await writeFile(
    png,
    // Density 200 then back down, as the site card is: crisp edges at 1200×630,
    // the size Layout.astro's og:image:width and height promise.
    await sharp(Buffer.from(svg), { density: 200 })
      .resize(RELEASE_CARD.WIDTH, RELEASE_CARD.HEIGHT)
      .png({ palette: true })
      .toBuffer(),
  );
  console.log(`  changelog/${release.version}.png`);
}

// A manifest entry for a release that no longer has a summary would point its
// page at a card for words the CHANGELOG no longer says.
const orphaned = Object.keys(recorded).filter((version) => !(version in manifest));

if (check) {
  if (stale.length > 0 || orphaned.length > 0) {
    const what = [
      stale.length > 0 ? `out of date: ${stale.join(", ")}` : "",
      orphaned.length > 0 ? `recorded with no summary: ${orphaned.join(", ")}` : "",
    ].filter(Boolean);
    console.error(
      `release cards ${what.join("; ")} — run \`make changelog\` on a Mac and commit the result.`,
    );
    process.exit(1);
  }
  console.log(`release cards: ${releases.length} up to date`);
  process.exit(0);
}

await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`release cards: ${stale.length} rendered, ${releases.length - stale.length} unchanged`);
