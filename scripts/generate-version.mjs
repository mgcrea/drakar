#!/usr/bin/env node
// Generate every copy of the release version from the Xcode project.
//
// The number lived in two places written in two shapes: `MARKETING_VERSION` in
// the pbxproj said 1.0.0 and the website said 1.0. Harmless today, and exactly
// how contour's footer came to sit at v1.0 for two releases — a copy nobody
// regenerates is a copy that drifts the moment the two stop matching.
//
// ## Why MARKETING_VERSION
//
// Pochette's script, which is cadence's, which is cupertino's adapted. Drakar is
// sold direct rather than through the App Store, but its release commit bumps
// `MARKETING_VERSION` by hand (`chore(release): Drakar 1.1.0`), and the signed
// build is cut from that commit, so the pbxproj is still what the binary carries.
// The root package.json is private and its version is meaningless.
//
// ## --check
//
// Regenerate into memory, exit non-zero on any difference, write nothing. Wire
// it into CI and a release commit that forgets a copy is a red build rather
// than a stale site.
//
//   pnpm version:sync     # write
//   pnpm version:check    # verify, write nothing

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CHECK = process.argv.includes("--check");

const read = (rel) => readFileSync(join(ROOT, rel), "utf8");

// ─── the source ──────────────────────────────────────────────────────────────

const CHANGELOG = "CHANGELOG.md";
const PBXPROJ = "apps/apple/Drakar.xcodeproj/project.pbxproj";

/**
 * `MARKETING_VERSION` from the *app* target, not from whatever matches first.
 *
 * A pbxproj holds one `XCBuildConfiguration` block per (target, configuration)
 * pair, and the test targets carry their own `MARKETING_VERSION` — usually left
 * at Xcode's 1.0 default, because nobody ever bumps a test bundle. Grabbing the
 * first match in the file is therefore a coin flip that silently returns 1.0.
 *
 * An app target is identified by a `PRODUCT_BUNDLE_IDENTIFIER` that does not
 * end in `Tests`, which is the same discriminator the deployment-target audit
 * used. Every such configuration is collected and they are required to agree:
 * a disagreement is a real defect (it means a release was bumped in one place
 * and not another) and it must not be papered over by preferring one.
 *
 * ## Why the block's own object id is the key
 *
 * Drakar has two app-side targets, the app and its DrakarHost helper, and both
 * carry the release's version. Cadence grew a second app
 * target (`Cadence` for macOS, `CadenceMobile` for iOS) sharing one bundle id,
 * because App Store universal purchase needs one record for both. There, neither the
 * configuration name nor the bundle id identifies a block: keying by either
 * collapses four blocks into two, the second target silently overwrites the
 * first, and a genuine disagreement passes as agreement.
 *
 * That is not hypothetical. Keyed by configuration name, this function reported
 * "1 target(s) match MARKETING_VERSION (1.2.0)" and exited 0 with the iOS target
 * sitting on 9.9.9.
 *
 * The 24-hex object id is unique per block, so that is the key. The target name
 * is resolved separately, from the `XCConfigurationList` comments, purely so the
 * error can say *which* target disagreed rather than just naming a configuration
 * that now exists twice.
 */
const configurationOwners = (source) => {
  const owners = new Map();
  const lists = source.matchAll(
    /\/\* Build configuration list for PBXNativeTarget "([^"]+)" \*\/ = \{\s*isa = XCConfigurationList;(.*?)\n\t\t\};/gs,
  );
  for (const [, targetName, body] of lists) {
    for (const [, id] of body.matchAll(/([0-9A-F]{24}) \/\* \w+ \*\//g)) {
      owners.set(id, targetName);
    }
  }
  return owners;
};

const marketingVersion = () => {
  const source = read(PBXPROJ);
  const owners = configurationOwners(source);
  const blocks = source.matchAll(
    /([0-9A-F]{24}) \/\* (\w+) \*\/ = \{\s*isa = XCBuildConfiguration;(.*?)\n\t\t\};/gs,
  );
  const found = new Map();
  for (const [, id, configuration, body] of blocks) {
    const bundleId = /PRODUCT_BUNDLE_IDENTIFIER = ([^;]+)/.exec(body)?.[1]?.trim();
    if (!bundleId || bundleId.endsWith("Tests")) continue;
    const version = /MARKETING_VERSION = ([^;]+)/.exec(body)?.[1]?.trim();
    if (version) found.set(id, { label: `${owners.get(id) ?? id}/${configuration}`, version });
  }
  const distinct = new Set([...found.values()].map((f) => f.version));
  if (distinct.size === 0) {
    console.error(`${PBXPROJ}: no app target carries a MARKETING_VERSION.`);
    process.exit(3);
  }
  if (distinct.size > 1) {
    const detail = [...found.values()].map((f) => `${f.label}=${f.version}`).join(", ");
    console.error(
      `${PBXPROJ}: the app targets disagree on MARKETING_VERSION (${detail}).\n` +
        `  A release bumped one and not another; fix the pbxproj before generating.`,
    );
    process.exit(3);
  }
  APP_CONFIGURATIONS = found.size;
  return [...distinct][0];
};

/** How many app-target configurations carried the version, for the summary. */
let APP_CONFIGURATIONS = 0;

const VERSION = marketingVersion();

/**
 * A bare `MAJOR.MINOR.PATCH`, with the prerelease/build tail semver allows.
 *
 * `CFBundleShortVersionString` is not free-form, and a version Apple will not
 * accept fails at upload — long after the site has been published claiming it.
 */
if (!/^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$/.test(VERSION)) {
  console.error(
    `MARKETING_VERSION is not a bare semver version: ${JSON.stringify(VERSION)}\n` +
      `  It becomes CFBundleShortVersionString and the version the website advertises.`,
  );
  process.exit(2);
}

// ─── marked regions ──────────────────────────────────────────────────────────

const BANNER = "generated from MARKETING_VERSION by `pnpm version:sync` — do not edit by hand";

/** Byte-identical to cupertino's, and for the same reasons. */
const region = (source, open, close, body, label) => {
  const start = source.indexOf(open);
  const end = source.indexOf(close);
  if (start === -1 || end === -1 || end < start) {
    console.error(`${label}: could not find the generated region (${open.trim()})`);
    process.exit(3);
  }
  return source.slice(0, start + open.length) + body + source.slice(end);
};

const targets = [];
const target = (path, next) => targets.push({ path, next });

// ─── The website's APP_VERSION ───────────────────────────────────────────────

target("apps/website/src/config.ts", (src) =>
  region(
    src,
    `// <generated:version> ${BANNER}\n`,
    `// </generated:version>`,
    `export const APP_VERSION = "${VERSION}";\n`,
    "website config.ts",
  ),
);

// ─── run ─────────────────────────────────────────────────────────────────────

let changed = 0;
for (const { path, next } of targets) {
  let before;
  try {
    before = read(path);
  } catch (err) {
    console.error(`missing target: ${path} (${String(err)})`);
    process.exit(3);
  }
  const after = next(before);
  if (before === after) continue;
  changed += 1;
  if (CHECK) {
    console.error(`  drifted: ${path}`);
  } else {
    writeFileSync(join(ROOT, path), after);
    console.log(`  updated: ${path}`);
  }
}

if (CHECK && changed) {
  console.error(
    `\n${changed} file(s) do not match MARKETING_VERSION. ` +
      `Run \`pnpm version:sync\` and commit the result.`,
  );
  process.exit(1);
}

/**
 * The CHANGELOG heading is checked, never written.
 *
 * A release whose version has no section is a release nobody wrote down, and
 * the appcast and the site's /changelog/ page are rendered from it. Generating an empty
 * heading would satisfy the check while telling every reader nothing, so this
 * reports and refuses instead.
 */
let changelog;
try {
  changelog = read(CHANGELOG);
} catch {
  // A clean message, not a stack trace: the file simply lives somewhere else in
  // some repos (balise keeps it at the root, the App Store ones under
  // apps/apple), and the fix is to correct one constant.
  console.error(`missing CHANGELOG: ${CHANGELOG} — set CHANGELOG at the top of this script.`);
  process.exit(3);
}
/**
 * Before the first release there is nothing to write down: the CHANGELOG says
 * "Nothing has shipped yet" and carries only `## [Unreleased]`, which becomes
 * `## [1.0.0]` on the day it ships. So the check is skipped while no released
 * section exists at all, and strict from the first one on. It expires by
 * itself; nothing needs flipping at launch.
 */
const everReleased = /^## \[[0-9]+\.[0-9]+\.[0-9]+/m.test(changelog);
if (!everReleased) {
  console.log(`${CHANGELOG}: nothing released yet, so no "## [${VERSION}]" section is required.`);
} else if (!new RegExp(`^## \\[${VERSION.replace(/[.+]/g, "\\$&")}\\]`, "m").test(changelog)) {
  const what = CHECK ? "" : "\n  Everything else was still written.";
  console.error(
    `${CHANGELOG} has no "## [${VERSION}]" section.\n` +
      `  The appcast, the What's New pane and /changelog/ are written from it.${what}`,
  );
  process.exit(1);
}

if (CHECK) {
  console.log(
    `version: ${VERSION} across ${APP_CONFIGURATIONS} app configuration(s), ` +
      `${targets.length} generated file(s) in sync`,
  );
} else if (changed === 0) {
  console.log(`version: already up to date (${VERSION})`);
} else {
  console.log(`\nversion: ${changed} file(s) updated from MARKETING_VERSION (${VERSION}).`);
}
