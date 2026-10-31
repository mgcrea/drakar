/**
 * The release card's composer, against the real icon.
 *
 * `composeCard` has no suite: its words are fixed in config.ts and somebody looks
 * at og-image.png whenever they change. A release card's title is not fixed. It
 * comes from CHANGELOG.md, written on release day by whoever cuts it, and baked
 * into a PNG nobody may open before it is shared. So what these hold is the part
 * nobody looks at: the wrap, the refusal of a third line, the date's zone, the
 * escape, and the band X crops.
 *
 * Run by the root's `pnpm test:scripts`, whose glob names this directory.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { composeReleaseCard, estimateWidth, RELEASE_CARD, wrapLines } from "./social-card.mjs";

const design = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "design");
const icon = readFileSync(join(design, "drakar-icon.svg"), "utf8");

describe("composeReleaseCard", () => {
  const release = {
    version: "1.9.0",
    date: "2026-09-28",
    title: "Move sessions between Claude accounts, ended ones too.",
    footer: "drakar.mgcrea.io/changelog",
  };
  const svg = composeReleaseCard(icon, release);
  const width = RELEASE_CARD.WIDTH - 2 * RELEASE_CARD.MARGIN;

  it("is the size the og:image tags declare", () => {
    assert.match(svg, /width="1200" height="630"/);
  });

  it("says the version, the date and the title", () => {
    assert.match(svg, />Drakar<tspan[^>]*>1\.9\.0<\/tspan>/);
    assert.match(svg, />September 28, 2026 · drakar\.mgcrea\.io\/changelog</);
    assert.match(svg, />Move sessions between Claude</);
    assert.match(svg, />accounts, ended ones too\.</);
  });

  it("separates the word from the version with an offset, not a space", () => {
    // librsvg drops a space, ordinary or no-break, that opens a <tspan>, so the
    // first renders read "Drakar1.9.0".
    assert.match(svg, /<tspan dx="\d+"/);
  });

  it("dates the card in UTC, whatever the zone it is rendered in", () => {
    // A New Year's Day release rendered west of Greenwich would read December 31
    // under a local-time conversion.
    const card = composeReleaseCard(icon, { ...release, date: "2027-01-01" });
    assert.match(card, />January 1, 2027 ·/);
  });

  it("escapes the title, which comes from prose", () => {
    const card = composeReleaseCard(icon, { ...release, title: "Codex & <Grok>" });
    assert.match(card, /Codex &amp; &lt;Grok&gt;/);
    assert.doesNotMatch(card, /<Grok>/);
  });

  it("namespaces the icon's ids, as the site card does", () => {
    assert.match(svg, /id="icon-clip"/);
    assert.doesNotMatch(svg, /url\(#clip\)/);
  });

  it("wraps on whole words and fits two lines", () => {
    const lines = wrapLines(release.title, RELEASE_CARD.TITLE, width);
    assert.equal(lines.length, 2);
    assert.equal(lines.join(" "), release.title);
    for (const line of lines) assert.ok(estimateWidth(line, RELEASE_CARD.TITLE) <= width);
  });

  it("sets a one-line title half a leading lower, between the label and the footer", () => {
    const card = composeReleaseCard(icon, { ...release, title: "One line." });
    const y = RELEASE_CARD.TITLE_Y + RELEASE_CARD.TITLE_LEADING / 2;
    assert.match(card, new RegExp(`y="${y}"[^>]*\\n[^>]*font-size="${RELEASE_CARD.TITLE}"`));
  });

  it("refuses a title that needs a third line, rather than letting it run into the footer", () => {
    assert.throws(
      () =>
        composeReleaseCard(icon, {
          ...release,
          title: "MOST WINDOWS NOW WORK WITH CODEX, GROK BUILD AND CLAUDE, WOW WOW WOW.",
        }),
      /needs 3 lines on the card/,
    );
  });

  it("refuses a single word wider than the card, which the wrap cannot split", () => {
    assert.throws(
      () => composeReleaseCard(icon, { ...release, title: "W".repeat(30) }),
      /wider than the card/,
    );
  });

  it("refuses a version or a date that is not a release's", () => {
    assert.throws(() => composeReleaseCard(icon, { ...release, version: "Unreleased" }));
    assert.throws(() => composeReleaseCard(icon, { ...release, date: "" }));
  });

  it("keeps every line of text out of the band X crops", () => {
    const ys = [...svg.matchAll(/<text x="[^"]+" y="(\d+)"/g)].map((m) => Number(m[1]));
    assert.equal(ys.length, 4, "the label, two title lines and the footer");
    for (const y of ys) {
      assert.ok(y >= RELEASE_CARD.SAFE_INSET && y <= RELEASE_CARD.HEIGHT - RELEASE_CARD.SAFE_INSET);
    }
  });
});
