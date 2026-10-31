/**
 * The og:image cards, composed from `design/drakar-icon.svg` rather than drawn
 * beside it: the site's (`composeCard`) and one per release (`composeReleaseCard`).
 *
 * Armada's composers, copied: the direct-distribution apps share no package. It
 * DIVERGES from armada in where the colours come from. Armada reads them from its
 * `design/colors.json`; Drakar has no such file, and its icon is the only place
 * its colours are written down, so `PALETTE` below quotes the icon's plate stops
 * and the site's own text colour. Change the plate, change both.
 *
 * And in the plate's corners. `design/drakar-icon.svg` is full-bleed and square,
 * because `make icon` hands it to Icon Composer, which applies the squircle
 * itself. On a card nothing does, so `icon()` clips it to the plate's corner,
 * 230/1024, the radius the site rounds every Drakar mark with.
 *
 * It is a vertical stack, not the siblings' horizontal lockup, for a mechanical
 * reason: centring icon and word as one block needs the word's rendered width,
 * which the siblings get from a CoreText measurement typed into their module.
 * Stacked and centred with `text-anchor="middle"`, nothing here needs measuring.
 *
 * Nothing is redrawn. The sails, the water, the plate and the squircle all come
 * from the embedded icon; the only numbers here are layout.
 *
 * Baked, not served: `pnpm icons` renders this to PNG on the machine that runs it,
 * so the typeface resolves there. That is safe only because it runs on a Mac.
 * Rendered on Linux, the system stack would silently fall back to another font.
 */

const CARD = { WIDTH: 1200, HEIGHT: 630, SAFE_INSET: 60 };

/**
 * Layout, top to bottom. X renders `summary_large_image` at 2:1 while og:image is
 * 1.91:1, so roughly 15px comes off the top and bottom; SAFE_INSET keeps every
 * mark well clear of that band, and `composeCard` throws rather than crossing it.
 */
const ICON = 148;
const ICON_Y = 104;
const WORD = 76;
const WORD_Y = 340;
const HEADLINE = 40;
const HEADLINE_Y = 436;
const SUBHEAD = 27;
const SUBHEAD_Y = 490;

/** The card's own ground: the page background, ramped, as bastion's card is. */
const GROUND = ["#15161b", "#08090b"];

/**
 * The icon's two plate stops (`#plate` in design/drakar-icon.svg), each glowing
 * from one side of the icon, and the words in the site's --color-fg.
 */
const PALETTE = { ink: "#f4f2ef", glowA: "#007AFF", glowB: "#AF52DE" };

/** The plate's corner radius in the icon's own 1024 units: Apple's 230/1024. */
const PLATE_RADIUS = 230;

const FONT_STACK =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif';

/** Throws rather than passing the artwork through: every check guards a silent failure. */
const expect = (condition, message) => {
  if (!condition) throw new Error(`drakar social card: ${message}`);
};

const escapeXml = (text) =>
  text.replace(
    /[&<>"]/g,
    (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[char],
  );

/** Everything between the root `<svg>` tag and its close. One known generated file. */
const bodyOf = (svg) => {
  const match = /<svg\b[^>]*>([\s\S]*)<\/svg>\s*$/.exec(svg);
  expect(match, "the icon does not look like an SVG document");
  return match[1];
};

/**
 * Renames every id in the embedded icon and every `url(#…)` pointing at one. The
 * icon ships ids as generic as `c` and `sky`, and it is about to share an id space
 * with the card's own gradients.
 */
const namespaceIds = (body, prefix) => {
  const ids = [...body.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  expect(ids.length > 0, "the icon defines no ids; has its structure changed?");
  return ids.reduce(
    (text, id) =>
      text
        .replaceAll(`id="${id}"`, `id="${prefix}${id}"`)
        .replaceAll(`url(#${id})`, `url(#${prefix}${id})`),
    body,
  );
};

const viewBoxOf = (svg) => {
  const match = /\bviewBox="0 0 (\d+(?:\.\d+)?) (\d+(?:\.\d+)?)"/.exec(svg);
  expect(match, 'the icon has no `viewBox="0 0 w h"` to scale from');
  const [width, height] = [Number(match[1]), Number(match[2])];
  expect(width === height, `the icon is not square (${width}×${height})`);
  return width;
};

/**
 * The icon's body, its ids namespaced, scaled to `size` and centred across the
 * card at `y`. Nothing is redrawn; see the top of this file.
 */
const icon = (iconSvg, y, size) => {
  const source = viewBoxOf(iconSvg);
  const body = namespaceIds(bodyOf(iconSvg), "icon-")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<title>[\s\S]*?<\/title>/g, "")
    .replace(/^\s*\n/gm, "")
    .trim();
  expect(body.includes("clip-path"), "the icon body lost its clip; is it the generated file?");
  return `  <clipPath id="plate-corner"><rect width="${source}" height="${source}" rx="${PLATE_RADIUS}"/></clipPath>
  <g transform="translate(${(CARD.WIDTH - size) / 2} ${y}) scale(${size / source})" clip-path="url(#plate-corner)">
${body}
  </g>`;
};

/**
 * The page background ramped top to bottom, with the plate's two colours glowing
 * either side of the icon at `glowY`, blue on the left and violet on the right, as
 * the plate runs. Shared, so the site card and a release card shared in the same
 * feed read as one family.
 */
const ground = (glowY) => `  <defs>
    <linearGradient id="ground" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="${CARD.HEIGHT}">
      <stop offset="0" stop-color="${GROUND[0]}"/>
      <stop offset="1" stop-color="${GROUND[1]}"/>
    </linearGradient>
${[
  ["glow-a", PALETTE.glowA, CARD.WIDTH / 2 - 190],
  ["glow-b", PALETTE.glowB, CARD.WIDTH / 2 + 190],
]
  .map(
    ([
      id,
      color,
      cx,
    ]) => `    <radialGradient id="${id}" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${glowY}" r="520">
      <stop offset="0" stop-color="${color}" stop-opacity="0.24"/>
      <stop offset="0.55" stop-color="${color}" stop-opacity="0.05"/>
      <stop offset="1" stop-color="${color}" stop-opacity="0"/>
    </radialGradient>`,
  )
  .join("\n")}
  </defs>
  <rect width="${CARD.WIDTH}" height="${CARD.HEIGHT}" fill="url(#ground)"/>
  <rect width="${CARD.WIDTH}" height="${CARD.HEIGHT}" fill="url(#glow-a)"/>
  <rect width="${CARD.WIDTH}" height="${CARD.HEIGHT}" fill="url(#glow-b)"/>`;

const line = ({ text, y, size, fill, weight, opacity }) =>
  `  <text x="${CARD.WIDTH / 2}" y="${y}" fill="${fill}"${
    opacity ? ` opacity="${opacity}"` : ""
  } text-anchor="middle"
        font-family='${FONT_STACK}' font-size="${size}" font-weight="${weight}">${escapeXml(text)}</text>`;

/**
 * @param {string} iconSvg contents of `design/drakar-icon.svg`
 * @param {{ headline: string, subhead: string, width: number, height: number }} copy
 * @returns {string} the card SVG, for sharp to rasterise
 */
export const composeCard = (iconSvg, { headline, subhead, width, height }) => {
  expect(
    width === CARD.WIDTH && height === CARD.HEIGHT,
    `config says ${width}×${height}, the composer draws ${CARD.WIDTH}×${CARD.HEIGHT}`,
  );
  expect(headline && subhead, "the card needs both a headline and a subhead");

  const sail = PALETTE.ink;

  const lowest = SUBHEAD_Y + SUBHEAD * 0.25;
  expect(ICON_Y >= CARD.SAFE_INSET, "the icon sits inside the band X crops away");
  expect(
    lowest <= CARD.HEIGHT - CARD.SAFE_INSET,
    `the subhead reaches ${Math.round(lowest)}, inside the band X crops away`,
  );

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CARD.WIDTH}" height="${CARD.HEIGHT}"
     viewBox="0 0 ${CARD.WIDTH} ${CARD.HEIGHT}" role="img" aria-label="Drakar">
  <!-- GENERATED by apps/website/scripts/generate-icons.mjs — do not edit. -->
${ground(ICON_Y + ICON / 2)}
${icon(iconSvg, ICON_Y, ICON)}
${line({ text: "Drakar", y: WORD_Y, size: WORD, fill: sail, weight: 600 })}
${line({ text: headline, y: HEADLINE_Y, size: HEADLINE, fill: sail, weight: 500 })}
${line({ text: subhead, y: SUBHEAD_Y, size: SUBHEAD, fill: sail, weight: 400, opacity: "0.62" })}
</svg>
`;
};

// ─── the release card ─────────────────────────────────────────────────────────
//
// One per version, for the link to /changelog/<version>/: the picture X, Slack and
// iMessage show when somebody shares a release. The site card's ground, glow and
// centred stack, so the two read as one family in a feed, but carrying the
// version, the release's own title and its date, so two releases shared in one
// feed do not look like the same post.
//
// Baked on a Mac and committed, for the reason og-image.png is: the font resolves
// on the machine that renders it, and Linux CI would swap it.
//
// Unlike `composeCard`, this one has to fit text it did not choose: a title from
// CHANGELOG.md. There are no font metrics at render time, and the reason this file
// stacks rather than measures holds here too, so it wraps on an ESTIMATE of each
// character's advance in SF Pro Display semibold, generous rather than exact, and
// refuses a title that needs a third line rather than letting it run into the
// footer. `SUMMARY_TITLE_MAX` in scripts/lib/changelog.mjs is the matching bound
// on the source side, and a test there asks this wrap, so a title is turned down
// in `pnpm test:scripts` long before it reaches here. Centred lines need no
// measuring either way: each is its own `text-anchor="middle"`.

const RELEASE = {
  /** The narrowest the title may set, each side. Wider than SAFE_INSET: centred text needs air. */
  MARGIN: 90,
  ICON: 112,
  ICON_Y: 66,
  LABEL: 34,
  LABEL_Y: 240,
  TITLE: 58,
  TITLE_LEADING: 70,
  /** The first baseline of a two-line title. A one-line title sits half a leading lower. */
  TITLE_Y: 336,
  FOOT: 24,
  FOOT_Y: 516,
};

/** Advance per em, roughly, by character class. Over-estimates on purpose. */
const advance = (char) => {
  if (char === " ") return 0.27;
  if (/[iljI.,:;'!|]/.test(char)) return 0.27;
  if (/[ftr()-]/.test(char)) return 0.36;
  if (/[mwMW]/.test(char)) return 0.86;
  if (/[A-Z]/.test(char)) return 0.68;
  if (/[0-9]/.test(char)) return 0.6;
  return 0.55;
};

/** Estimated width of `text` at `size`px. */
export const estimateWidth = (text, size) =>
  [...text].reduce((sum, char) => sum + advance(char), 0) * size;

/**
 * Greedy word wrap on the estimate. Returns the lines; never splits a word.
 *
 * @param {string} text
 * @param {number} size
 * @param {number} maxWidth
 * @returns {string[]}
 */
export const wrapLines = (text, size, maxWidth) => {
  const lines = [];
  let current = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const candidate = current ? `${current} ${word}` : word;
    if (current && estimateWidth(candidate, size) > maxWidth) {
      lines.push(current);
      current = word;
    } else {
      current = candidate;
    }
  }
  if (current) lines.push(current);
  return lines;
};

/** "2026-09-28" → "September 28, 2026", in UTC so the build machine's zone cannot move it. */
const longDate = (iso) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });

/**
 * Composes one release's social card.
 *
 * @param {string} iconSvg contents of `design/drakar-icon.svg`
 * @param {{ version: string, date: string, title: string, footer?: string }} release
 *   `title` is plain text, already stripped of markdown (`plain` in changelog.mjs)
 * @returns {string} the card SVG, for sharp to rasterise
 */
export const composeReleaseCard = (iconSvg, { version, date, title, footer }) => {
  const sail = PALETTE.ink;
  expect(/^\d+\.\d+\.\d+$/.test(version ?? ""), `not a release version: ${version}`);
  expect(/^\d{4}-\d{2}-\d{2}$/.test(date ?? ""), `not a release date: ${date}`);
  expect(title, "the release card needs a title");

  const textWidth = CARD.WIDTH - 2 * RELEASE.MARGIN;
  const lines = wrapLines(title, RELEASE.TITLE, textWidth);
  expect(
    lines.length <= 2,
    `"${title}" needs ${lines.length} lines on the card; it has room for two — shorten it`,
  );
  for (const each of lines) {
    // A single word wider than the card: the wrap never splits one, so it would
    // set past both margins rather than wrap.
    expect(estimateWidth(each, RELEASE.TITLE) <= textWidth, `"${each}" is wider than the card`);
  }

  const first = RELEASE.TITLE_Y + ((2 - lines.length) * RELEASE.TITLE_LEADING) / 2;
  const lastTitle = first + (lines.length - 1) * RELEASE.TITLE_LEADING;
  expect(RELEASE.ICON_Y >= CARD.SAFE_INSET, "the icon sits inside the band X crops away");
  expect(
    lastTitle + RELEASE.TITLE * 0.25 < RELEASE.FOOT_Y - RELEASE.FOOT * 1.5,
    "the title runs into the footer",
  );
  expect(
    RELEASE.FOOT_Y + RELEASE.FOOT * 0.25 <= CARD.HEIGHT - CARD.SAFE_INSET,
    "the footer sits inside the band X crops away",
  );

  const foot = [longDate(date), footer].filter(Boolean).join(" · ");
  // The word at full strength and the version a step back, in one centred line.
  // The gap is a `dx` of about a space's advance, not a character: librsvg drops
  // a space, ordinary or no-break, that opens a `<tspan>`, and both renders read
  // "Drakar1.1.0". A `dx` still counts toward the centred line's width.
  const label = `Drakar<tspan dx="${Math.round(RELEASE.LABEL * 0.27)}" font-weight="500" opacity="0.62">${escapeXml(version)}</tspan>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CARD.WIDTH}" height="${CARD.HEIGHT}"
     viewBox="0 0 ${CARD.WIDTH} ${CARD.HEIGHT}" role="img" aria-label="${escapeXml(
       `Drakar ${version}: ${title}`,
     )}">
  <!-- GENERATED by apps/website/scripts/generate-release-cards.mjs — do not edit. -->
  <title>${escapeXml(`Drakar ${version}`)}</title>
${ground(RELEASE.ICON_Y + RELEASE.ICON / 2)}
${icon(iconSvg, RELEASE.ICON_Y, RELEASE.ICON)}
  <text x="${CARD.WIDTH / 2}" y="${RELEASE.LABEL_Y}" fill="${sail}" text-anchor="middle"
        font-family='${FONT_STACK}' font-size="${RELEASE.LABEL}" font-weight="600">${label}</text>
${lines
  .map((text, i) =>
    line({
      text,
      y: first + i * RELEASE.TITLE_LEADING,
      size: RELEASE.TITLE,
      fill: sail,
      weight: 600,
    }),
  )
  .join("\n")}
${line({ text: foot, y: RELEASE.FOOT_Y, size: RELEASE.FOOT, fill: sail, weight: 400, opacity: "0.62" })}
</svg>
`;
};

/** Exported for the tests, which assert the geometry rather than re-derive it. */
export const RELEASE_CARD = { ...CARD, ...RELEASE };
