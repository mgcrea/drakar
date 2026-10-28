import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { HIDDEN_SECTIONS, parse, renderHTML, renderMarkdown, visibleGroups } from "./changelog.mjs";

/**
 * The failures these guard against are silent in both directions.
 *
 * Two consumers read this parse — the Sparkle appcast every user sees when they
 * update, and the generated What's New pane inside the app — and a shape neither
 * anticipated does not crash: it drops a bullet from one of them while the other
 * keeps rendering. Nobody notices for a release or two.
 *
 * The fixture is not a tidy example. It is the awkward shapes the real
 * CHANGELOG.md actually contains:
 *
 *   - a `###` group whose prose sits between the heading and the first bullet
 *   - a bullet with NO bold headline at all
 *   - a bold headline with a code span inside it
 *   - a bullet with a second paragraph after a blank line
 *   - a bare number, which the placeholder restoration once ate as an index
 *   - a `## [Unreleased]` heading, which carries no date
 *   - a `### Internal` group, which no renderer may show a user
 */
const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));

const FIXTURE = `# Changelog

Intro prose that belongs to no release.

<!-- <generated:version> generated from package.json by \`make version\` -->

## [Unreleased]

### Changed

- **Something.** In flight.

## [1.2.0] - 2026-03-04

### Fixed

Not every fix here is a bullet; this line is the group's own lead.

- **A surface that shells out to \`node\` could not find it.** From March 2026
  onward the gateway answers 400 and keeps serving.

  A second paragraph, after a blank line.

- **Plain.** One line only.

### Note for 1.0.0 users

- No headline on this one at all.

### Internal

- **CI.** Repo-facing prose that no user should be shown.

## [1.0.0] - 2026-01-31

### Added

- **First.** It shipped.
`;

describe("parse", () => {
  const releases = parse(FIXTURE);

  it("reads every section newest first, and skips the intro and its generated region", () => {
    assert.deepEqual(
      releases.map((r) => r.version),
      ["Unreleased", "1.2.0", "1.0.0"],
    );
    assert.equal(releases[0].unreleased, true);
    assert.equal(releases[0].date, "");
    assert.equal(releases[1].unreleased, false);
    assert.equal(releases[1].date, "2026-03-04");
  });

  it("keeps a group's lead prose", () => {
    const fixed = releases[1].groups[0];
    assert.equal(fixed.name, "Fixed");
    assert.deepEqual(fixed.lead, [
      "Not every fix here is a bullet; this line is the group's own lead.",
    ]);
  });

  it("splits a bold headline off, code span and all", () => {
    const [first] = releases[1].groups[0].entries;
    assert.equal(first.headline, "A surface that shells out to `node` could not find it.");
    assert.deepEqual(first.body, [
      "From March 2026 onward the gateway answers 400 and keeps serving.",
      "A second paragraph, after a blank line.",
    ]);
  });

  it("joins continuation lines with a single space", () => {
    const [first] = releases[1].groups[0].entries;
    assert.equal(
      first.paragraphs[0],
      "**A surface that shells out to `node` could not find it.** From March 2026 onward the gateway answers 400 and keeps serving.",
    );
  });

  it("allows a bullet with no headline, under a freely named section", () => {
    const notes = releases[1].groups[1];
    assert.equal(notes.name, "Note for 1.0.0 users");
    assert.equal(notes.entries[0].headline, null);
    assert.deepEqual(notes.entries[0].body, ["No headline on this one at all."]);
  });

  it("keeps a hidden section in the parse, for the renderers to drop", () => {
    assert.deepEqual(
      releases[1].groups.map((group) => group.name),
      ["Fixed", "Note for 1.0.0 users", "Internal"],
    );
    assert.deepEqual(
      visibleGroups(releases[1]).map((group) => group.name),
      ["Fixed", "Note for 1.0.0 users"],
    );
  });

  // DIVERGES from armada, whose parse has no `pending`: see the header of
  // changelog.mjs.
  it("reads `- Unreleased` as a version with no date yet, not as [Unreleased]", () => {
    const [pending, unreleased, dated] = parse(
      "## [1.1.0] - Unreleased\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-31\n",
    );
    assert.equal(pending.version, "1.1.0");
    assert.equal(pending.date, "");
    assert.equal(pending.pending, true);
    assert.equal(pending.unreleased, false);
    assert.equal(unreleased.pending, false);
    assert.equal(unreleased.unreleased, true);
    assert.equal(dated.pending, false);
  });
});

describe("renderHTML", () => {
  const [, release] = parse(FIXTURE);
  const html = renderHTML(release);

  it("renders the whole section exactly, without its Internal group", () => {
    assert.equal(
      html,
      [
        "<h3>Fixed</h3>",
        "<p>Not every fix here is a bullet; this line is the group's own lead.</p>",
        "<ul>",
        "<li><p><strong>A surface that shells out to <code>node</code> could not find it.</strong> " +
          "From March 2026 onward the gateway answers 400 and keeps serving.</p>" +
          "<p>A second paragraph, after a blank line.</p></li>",
        "<li><p><strong>Plain.</strong> One line only.</p></li>",
        "</ul>",
        "<h3>Note for 1.0.0 users</h3>",
        "<ul>",
        "<li><p>No headline on this one at all.</p></li>",
        "</ul>",
      ].join("\n"),
    );
  });

  it("does not eat a bare number as a code-span placeholder", () => {
    // The placeholder is delimited by private-use characters for exactly this
    // reason. With spaces, "March 2026 onward" rendered as
    // "Marchundefinedonward" — there is no 2026th code span.
    assert.match(html, /March 2026 onward/);
    assert.match(html, /answers 400 and/);
    assert.doesNotMatch(html, /undefined/);
  });
});

describe("renderMarkdown", () => {
  const [, release] = parse(FIXTURE);

  it("renders the whole section exactly, without its Internal group", () => {
    assert.equal(
      renderMarkdown(release),
      [
        "### Fixed",
        "",
        "Not every fix here is a bullet; this line is the group's own lead.",
        "",
        "- **A surface that shells out to `node` could not find it.** " +
          "From March 2026 onward the gateway answers 400 and keeps serving.",
        "",
        "  A second paragraph, after a blank line.",
        "- **Plain.** One line only.",
        "",
        "### Note for 1.0.0 users",
        "",
        "- No headline on this one at all.",
      ].join("\n"),
    );
  });

  it("renders nothing, in either format, for a section holding only hidden groups", () => {
    const [internalOnly] = parse(
      "## [0.1.0] - 2026-01-01\n\n### Internal\n\n- **CI.** Only this.\n",
    );
    assert.equal(renderMarkdown(internalOnly), "");
    assert.equal(renderHTML(internalOnly), "");
  });
});

describe("the real CHANGELOG.md", () => {
  const releases = parse(readFileSync(join(root, "CHANGELOG.md"), "utf8"));

  it("parses into dated releases with entries", () => {
    // DIVERGES from cupertino's `> 5`, a count of its own history. Armada's file
    // started with nothing but `## [Unreleased]`, so the floor is one section.
    assert.ok(releases.length > 0);
    for (const release of releases.filter((r) => !r.unreleased)) {
      assert.match(release.version, /^\d+\.\d+\.\d+$/);
      // DIVERGES from armada, which wants a date on every one: Drakar's first
      // section is `## [1.0.0] - Unreleased` until the tag dates it.
      if (!release.pending) assert.match(release.date, /^\d{4}-\d{2}-\d{2}$/);
      assert.ok(release.groups.length > 0, `${release.version} has no sections`);
    }
  });

  it("renders every section to HTML with no markdown left over", () => {
    for (const release of releases) {
      const html = renderHTML(release);
      assert.doesNotMatch(html, /\*\*/, `${release.version}: bold markers reached the appcast`);
      assert.doesNotMatch(html, /^- /m, `${release.version}: a literal bullet reached the appcast`);
    }
  });

  it("shows no hidden section in either rendering", () => {
    for (const release of releases) {
      for (const name of HIDDEN_SECTIONS) {
        assert.doesNotMatch(
          renderHTML(release),
          new RegExp(`<h3>${name}</h3>`),
          `${release.version}: ### ${name} reached the appcast`,
        );
        assert.doesNotMatch(
          renderMarkdown(release),
          new RegExp(`^### ${name}$`, "m"),
          `${release.version}: ### ${name} reached the release body`,
        );
      }
    }
  });

  it("round-trips every code span, over the whole file", () => {
    // Not `doesNotMatch(/undefined/)`: 1.3.0's prose is ABOUT a field that read
    // back as `undefined`, so the blunt check fails on a correct render. What
    // actually needs asserting is that no placeholder was eaten — every code
    // span in the source has to come out the other side as a <code>. Counted
    // over the visible groups, because a span in `### Internal` is meant to be
    // missing.
    for (const release of releases) {
      const sources = [
        ...release.lead,
        ...visibleGroups(release).flatMap((group) => [
          group.name,
          ...group.lead,
          ...group.entries.flatMap((entry) => entry.paragraphs),
        ]),
      ];
      const spans = sources.reduce((n, text) => n + (text.match(/`[^`]+`/g) ?? []).length, 0);
      const rendered = (renderHTML(release).match(/<code>/g) ?? []).length;
      assert.equal(rendered, spans, `${release.version}: ${spans - rendered} code span(s) lost`);
    }
  });
});

describe("changelog-notes.mjs", () => {
  const dir = mkdtempSync(join(tmpdir(), "changelog-notes-"));
  const file = join(dir, "CHANGELOG.md");
  // 0.9.0 holds nothing but a hidden group: a heading that matches, over notes
  // that would reach users empty.
  writeFileSync(
    file,
    `${FIXTURE}\n## [0.9.0] - 2026-01-01\n\n### Internal\n\n- Repo-facing prose only.\n`,
  );
  after(() => rmSync(dir, { recursive: true, force: true }));

  const notes = (...args) =>
    spawnSync(process.execPath, [join(root, "scripts", "changelog-notes.mjs"), ...args, file], {
      encoding: "utf8",
    });

  it("takes the named version's section, not the first one in the file", () => {
    const result = notes("--markdown", "1.0.0");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "### Added\n\n- **First.** It shipped.\n");
  });

  it("leaves Internal out of the appcast HTML and the release markdown alike", () => {
    for (const args of [["1.2.0"], ["--markdown", "1.2.0"]]) {
      const result = notes(...args);
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout, /Fixed/);
      assert.doesNotMatch(result.stdout, /Internal|Repo-facing/);
    }
  });

  it("exits non-zero rather than printing empty notes", () => {
    assert.equal(notes("--markdown", "9.9.9").status, 1);
    assert.equal(notes("0.9.0").status, 1);
    assert.equal(notes("--markdown", "0.9.0").status, 1);
  });
});

/*
 * DIVERGES from armada, whose block here is "summaries": the release summary
 * its website, social card and post are made from, and the limits each puts on
 * it. Drakar has no summary (see the header of changelog.mjs). What stays is
 * the half that is about the release's own lead, which the appcast and the
 * release body render whether or not a website exists.
 */
describe("a release's lead", () => {
  const SOURCE = `# Changelog

## [2.0.0] - 2026-10-03

**One line for the title.** Two sentences of description, wrapped
across lines the way the file wraps everything. With \`code\` and a [link](https://example.com).

A second paragraph of lead prose.

### Fixed

- **A fix.** Body.
`;
  const [release] = parse(SOURCE);

  it("joins the release's wrapped lead lines into paragraphs", () => {
    assert.equal(release.lead.length, 2);
    assert.match(release.lead[0], /description, wrapped across lines/);
  });

  it("renders a wrapped lead as one paragraph in the appcast, not one per line", () => {
    const html = renderHTML(release);
    assert.equal((html.match(/<p>/g) ?? []).length, 2 + 1);
    assert.match(html, /^<p><strong>One line for the title\.<\/strong> Two sentences/);
  });

  it("keeps the opening paragraph its own paragraph in the release body", () => {
    // `renderMarkdown` joined the lead with a space when it was one entry per
    // line. One entry per paragraph, the same join would run the opening
    // paragraph and the prose after it together.
    const [opening, second] = renderMarkdown(release).split("\n\n");
    assert.match(opening, /^\*\*One line for the title\.\*\* Two sentences/);
    assert.equal(second, "A second paragraph of lead prose.");
  });
});
