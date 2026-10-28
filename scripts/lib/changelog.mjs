// CHANGELOG.md, parsed once.
//
// Three things read this file and they must not disagree about it: the Sparkle
// appcast, which renders one section as HTML at release time; the GitHub release
// body, which renders the same section as markdown; and the app's What's New
// pane, which is generated from the most recent sections at build time. Two
// parsers over one hand-written file drift the first time somebody writes a
// bullet in a shape neither anticipated, and the failure is silent in both
// directions — the appcast keeps rendering while the pane quietly drops a
// bullet. So there is one parser, `renderHTML` below is the appcast's renderer
// moved here verbatim, and which sections a user is never shown is decided here
// once (`HIDDEN_SECTIONS`) rather than by each caller.
//
// Both renderers read `entry.paragraphs` and nothing else. That is the whole
// reason entries carry their raw paragraphs alongside the `headline`/`body`
// split the Swift generator wants: the release paths never see the split, so
// changing how the split works cannot move a byte of the appcast.
//
// Armada's, copied: the direct-distribution apps share no package. It DIVERGES
// from armada twice:
//
//   - No release summary (`Summary`, `plain`, `postText` and their limits).
//     Armada's exist for its website's /changelog/ pages, the social card each
//     release gets, and the post that links to it. Drakar has no website yet,
//     and a summary nothing renders is a limit nothing checks.
//   - `pending`, from cadence: `## [1.0.0] - Unreleased` is a version written
//     down before it has a date, which is what a build of 1.0.0 contains before
//     the tag. `## [Unreleased]` stays the name for work no version owns yet.

/**
 * One bullet.
 *
 * `paragraphs` is what the source said, with continuation lines joined by a
 * single space — the shape the HTML renderer has always emitted. `headline` is
 * the leading `**…**` span with its asterisks removed, or null: not every
 * bullet in this file opens with one, so a required headline would be a lie
 * about the format.
 *
 * @typedef {{ paragraphs: string[], headline: string | null, body: string[] }} Entry
 */

/**
 * One `### Added` / `### Fixed` block.
 *
 * `lead` is the prose that can sit between the heading and the first bullet.
 * It is easy to forget it exists; dropping it silently shortens the release
 * notes every user reads before agreeing to replace an app that runs agents
 * over their files.
 *
 * @typedef {{ name: string, lead: string[], entries: Entry[] }} Group
 */

/**
 * `lead` is the prose between the `## ` heading and the first `###`, one entry
 * per PARAGRAPH: wrapped lines joined, blank lines separating. Unlike a group's
 * lead, which the What's New pane renders line by line and so keeps its lines.
 *
 * `pending` is a version with no date yet: `## [1.0.0] - Unreleased`.
 *
 * @typedef {{ version: string, date: string, unreleased: boolean, pending: boolean, lead: string[], groups: Group[] }} Release
 */

/** The leading `**…**`, non-greedy so a headline containing a code span still ends at its own close. */
const HEADLINE = /^\*\*(.+?)\*\*\s*/;

/**
 * Every `## ` section, newest first.
 *
 * @param {string} markdown
 * @returns {Release[]}
 */
export const parse = (markdown) => {
  const lines = markdown.split("\n");
  /** @type {Release[]} */
  const releases = [];

  /** @type {Release | null} */
  let release = null;
  /** @type {Group | null} */
  let group = null;
  /** @type {string[] | null} */
  let bullet = null; // the paragraphs of the bullet being collected
  /** @type {string[]} */
  let paragraph = [];
  /** @type {string[]} */
  let leadParagraph = []; // the release-level lead paragraph being collected

  const flushLead = () => {
    if (release && leadParagraph.length) {
      release.lead.push(leadParagraph.join(" "));
      leadParagraph = [];
    }
  };

  const flushParagraph = () => {
    if (bullet && paragraph.length) {
      bullet.push(paragraph.join(" "));
      paragraph = [];
    }
  };
  const flushBullet = () => {
    if (!bullet) return;
    flushParagraph();
    const paragraphs = bullet;
    bullet = null;
    const first = paragraphs[0] ?? "";
    const match = HEADLINE.exec(first);
    const rest = match ? first.slice(match[0].length) : first;
    group?.entries.push({
      paragraphs,
      headline: match ? match[1] : null,
      body: [rest, ...paragraphs.slice(1)].filter((p) => p !== ""),
    });
  };

  for (const raw of lines) {
    const line = raw.trimEnd();

    if (line.startsWith("## ")) {
      flushBullet();
      flushLead();
      // `## [1.17.0] - 2026-09-07`, `## [1.0.0] - Unreleased`, or
      // `## [Unreleased]` with no date.
      const heading = line.slice(3).trim();
      const version = /^\[([^\]]+)\]/.exec(heading)?.[1] ?? heading;
      const date = /-\s*(\d{4}-\d{2}-\d{2})\s*$/.exec(heading)?.[1] ?? "";
      release = {
        version,
        date,
        unreleased: version.toLowerCase() === "unreleased",
        pending: /-\s*Unreleased\s*$/i.test(heading),
        lead: [],
        groups: [],
      };
      releases.push(release);
      group = null;
      continue;
    }

    // Everything above the first `## ` is the file's own intro — including the
    // `<generated:version>` region `make version` writes there. Not a release.
    if (!release) continue;

    if (line.startsWith("### ")) {
      flushBullet();
      flushLead();
      group = { name: line.slice(4).trim(), lead: [], entries: [] };
      release.groups.push(group);
    } else if (line.startsWith("- ")) {
      flushBullet();
      bullet = [];
      paragraph = [line.slice(2)];
    } else if (line === "") {
      flushParagraph();
      flushLead();
    } else if (bullet) {
      paragraph.push(line.trim());
    } else if (group) {
      // A group's prose, one entry per line, deliberately: the What's New pane
      // renders it that way, and joining it here would move the pane.
      group.lead.push(line.trim());
    } else {
      // The release's own prose. Joined into paragraphs: the appcast renders an
      // entry per `<p>`, and one per source line broke a wrapped sentence into
      // fragments in the update dialog. 1.0.0's two-line lead reached it as two
      // half-sentences, and no release since carried a lead to notice it again.
      leadParagraph.push(line.trim());
    }
  }
  flushBullet();
  flushLead();

  return releases;
};

// ─── What a user is shown ─────────────────────────────────────────────────────

/**
 * Sections that exist for the repository rather than for the user: prose about
 * CI and generators, which somebody deciding whether to update gets nothing from.
 *
 * This set used to live in `generate-changelog.mjs` alone, so the What's New pane
 * left `### Internal` out while the appcast and the GitHub release body put it in
 * front of every user. `parse` still keeps these groups, so a check over the
 * source can see them; every renderer drops them through `visibleGroups`.
 */
export const HIDDEN_SECTIONS = new Set(["Internal"]);

/**
 * A release's groups, minus `HIDDEN_SECTIONS`.
 *
 * @param {Release} release
 * @returns {Group[]}
 */
export const visibleGroups = (release) =>
  release.groups.filter((group) => !HIDDEN_SECTIONS.has(group.name));

// ─── HTML, for the appcast ────────────────────────────────────────────────────
//
// Moved here from `changelog-notes.mjs` character for character. Sparkle renders
// an item's `<description>` as HTML in a WKWebView, and the release path used to
// slice raw markdown straight into the CDATA: every user's update dialog showed
// literal `###` headings, `- ` bullets and `**` around each entry's lead.

const escape = (text) =>
  text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/**
 * Inline markdown. Code spans are lifted out first so nothing inside is touched.
 *
 * The placeholder wraps the index in private-use characters. Wrapping it in
 * spaces and restoring with `/ (\d+) /` also matches any bare number in ordinary
 * prose: "from March 2026 onward" came back as "from Marchundefinedonward",
 * because there is no 2026th code span. This CHANGELOG is full of years and
 * counts, so that is not a corner. U+E000 and U+E001 cannot appear in the source
 * — it is prose, not a font — and no rule below matches one. Private-use rather
 * than NUL so the restore pattern is not a control-character regex, which
 * oxlint rejects.
 */
export const inline = (text) => {
  const codes = [];
  let out = escape(text).replace(/`([^`]+)`/g, (_, code) => {
    codes.push(`<code>${code}</code>`);
    return `\uE000${codes.length - 1}\uE001`;
  });
  out = out
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])_([^_]+)_(?=[\s.,;:)]|$)/g, "$1<em>$2</em>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
  return out.replace(/\uE000(\d+)\uE001/g, (_, index) => codes[Number(index)]);
};

/**
 * One release as the HTML Sparkle shows.
 *
 * Reads `entry.paragraphs`, never `headline`/`body`, so the split those two
 * carry cannot move the output. Leaves out `HIDDEN_SECTIONS`.
 *
 * @param {Release} release
 * @returns {string}
 */
export const renderHTML = (release) => {
  const html = [];
  for (const text of release.lead) html.push(`<p>${inline(text)}</p>`);
  for (const group of visibleGroups(release)) {
    html.push(`<h3>${inline(group.name)}</h3>`);
    for (const text of group.lead) html.push(`<p>${inline(text)}</p>`);
    if (group.entries.length === 0) continue;
    html.push("<ul>");
    for (const entry of group.entries) {
      html.push(`<li>${entry.paragraphs.map((p) => `<p>${inline(p)}</p>`).join("")}</li>`);
    }
    html.push("</ul>");
  }
  return html.join("\n");
};

// ─── Markdown, for the GitHub release ─────────────────────────────────────────
//
// The release body used to be cut out of CHANGELOG.md with awk: the literal first
// section, whichever it was, `### Internal` and all. Rendered from the parse
// instead, it is the tag's own section with exactly the groups the appcast shows.
//
// Re-emitted rather than sliced, which costs the source's line wrapping: a wrapped
// paragraph comes back as one line, which GitHub renders the same. Slicing would
// need a second idea of where a section and a group end, which is the drift this
// file exists to prevent.

/**
 * One release as the markdown of a GitHub release body. Leaves out
 * `HIDDEN_SECTIONS`, as `renderHTML` does.
 *
 * A group's lead lines are joined into one paragraph. `parse` keeps a line per
 * entry there and does not record a blank line between two of its paragraphs, so
 * joining is the reading that is right for a wrapped paragraph, which is what
 * this file holds. The release's own lead is already one entry per paragraph, so
 * it keeps its paragraph breaks: joined with a space, its opening paragraph and
 * the prose after it would run together into one paragraph on the release page.
 *
 * @param {Release} release
 * @returns {string}
 */
export const renderMarkdown = (release) => {
  const blocks = [];
  blocks.push(...release.lead);
  for (const group of visibleGroups(release)) {
    blocks.push(`### ${group.name}`);
    if (group.lead.length > 0) blocks.push(group.lead.join(" "));
    if (group.entries.length === 0) continue;
    blocks.push(
      group.entries
        .map((entry) =>
          entry.paragraphs
            .map((text, index) => (index === 0 ? `- ${text}` : `  ${text}`))
            .join("\n\n"),
        )
        .join("\n"),
    );
  }
  return blocks.join("\n\n");
};
