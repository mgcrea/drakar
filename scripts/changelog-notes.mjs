#!/usr/bin/env node
// One CHANGELOG section, as HTML for the Sparkle appcast or as markdown for the
// GitHub release body.
//
// Sparkle renders an item's `<description>` as HTML in a WKWebView, and armada's
// `make appcast` used to slice the raw markdown straight into the CDATA. Every
// user's update dialog therefore showed literal `###` headings, `- ` bullets and
// `**` around the lead of each entry — the release notes somebody reads before
// agreeing to replace an app that runs agents over their files, rendered as
// source. Armada's file, copied: the direct-distribution apps share no package.
//
// ## Why a renderer here rather than a dependency
//
// The release path must not gain one for this. `make appcast` runs in CI
// between notarization and the upload, on a checkout whose node_modules exist
// for the packages rather than for the Makefile, and a markdown library is a
// supply-chain edge on the one target that signs a release. What the CHANGELOG
// actually uses is small and stable: `###` headings, bullets with continuation
// paragraphs, bold, italic, code spans and links. Anything richer — nested
// bullets, fenced code, tables — renders as its own source rather than
// wrongly, which is the failure this replaces and is why the omission is
// tolerable.
//
// The parse and both renderers live in `lib/changelog.mjs`, shared with the
// generator behind the app's What's New pane so that the three cannot disagree
// about what a bullet is, or about which sections (`HIDDEN_SECTIONS`) a user is
// never shown. What stays here is what is true of this caller and not of
// markdown: which section to take, the guards below, and escaping `]]>`.
//
// ## Why `--markdown`
//
// Armada's GitHub release body was the literal first section of the file, cut
// out with awk in the workflow: whatever section came first, `### Internal`
// included, and never checked against the tag. It now comes from here, so the
// release page and the update dialog are one section, chosen by version and
// guarded the same way.
//
// ## Why the version is an argument
//
// Armada's Makefile matched `## [$version]` rather than taking the top section,
// and failed the build when nothing matched, on the reasoning that a heading
// typo — `## [1.1]` against `## [1.1.0]` — would otherwise ship an update dialog
// with nothing in it. That guard moved in here with the slicing it guards, so the
// two cannot drift apart: this exits non-zero rather than printing an empty
// description, and neither `make appcast` nor the release job has a fallback
// that would paper over it.
//
//   node scripts/changelog-notes.mjs [--markdown] <version> [CHANGELOG.md]
import { readFileSync } from "node:fs";

import { HIDDEN_SECTIONS, parse, renderHTML, renderMarkdown } from "./lib/changelog.mjs";

const args = process.argv.slice(2);
const markdown = args.includes("--markdown");
const [version, file = "CHANGELOG.md"] = args.filter((arg) => arg !== "--markdown");
if (!version) {
  console.error("usage: changelog-notes.mjs [--markdown] <version> [CHANGELOG.md]");
  process.exit(2);
}

// Matched on the bracketed version alone so the ` - <date>` that follows it does
// not have to be known.
const release = parse(readFileSync(file, "utf8")).find((r) => r.version === version);
if (!release) {
  console.error(`no ${file} section '## [${version}]': the release notes would be empty`);
  process.exit(1);
}

// A section that matched its heading but holds nothing renderable is the same
// empty dialog the heading guard exists to stop, reached a different way. That
// includes a section with nothing in it but hidden groups.
const out = markdown ? renderMarkdown(release) : renderHTML(release);
if (!/\S/.test(out)) {
  const hidden = [...HIDDEN_SECTIONS].map((name) => `### ${name}`).join(", ");
  console.error(
    `${file} section '## [${version}]' has nothing to show once ${hidden} is left out: the release notes would be empty`,
  );
  process.exit(1);
}

// A `]]>` in the notes would end the CDATA section the Makefile wraps the HTML in.
process.stdout.write(markdown ? `${out}\n` : `${out.replaceAll("]]>", "]]]]><![CDATA[>")}\n`);
