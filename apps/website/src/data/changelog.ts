import changelog from "../../../../CHANGELOG.md?raw";
/**
 * The releases, for /changelog/ and /changelog/<version>/.
 *
 * Read from the repository's CHANGELOG.md at build time, `?raw`, and through the
 * parser the Sparkle appcast, the GitHub release body and the app's What's New
 * pane already share, so the four cannot disagree about what a release said.
 * `### Internal` is left out here as it is there, through the same
 * `visibleGroups`: it is about CI and the licence Worker, and these pages are for
 * somebody deciding whether to update.
 *
 * A release's social card exists only if `pnpm cards` rendered one, which it does
 * for every release with a summary. The manifest it writes is what says so, and a
 * page for a release without one falls back to the site card rather than linking
 * a picture that was never made.
 */
import {
  inline,
  parse,
  plain,
  postText,
  renderHTML,
  visibleGroups,
} from "../../../../scripts/lib/changelog.mjs";
import { APP_VERSION } from "../config";
import cards from "./release-cards.json";

export interface Release {
  version: string;
  date: string;
  /** "September 28, 2026", fixed to UTC so the build machine's zone cannot move it. */
  longDate: string;
  /** The page every share links to. */
  path: string;
  /** The `**Title.**` lead and its sentence or two, plain, when the release has one. */
  summary: { title: string; description: string; post: string } | null;
  /** The notes as HTML, without `### Internal`, and without the summary the page sets above them. */
  html: string;
  /** Each visible entry's bold headline, plain: the stand-in for a summary where there is none. */
  highlights: string[];
  /** The same headlines as inline HTML, so a command keeps its code styling in the index. */
  highlightsHtml: string[];
  /** `/changelog/<version>.png`, or null where no card was rendered. */
  card: string | null;
}

const longDate = (iso: string) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });

/**
 * Newest first, released only. `## [Unreleased]` sits in the file between
 * releases and is not something to link to.
 */
export const RELEASES: Release[] = parse(changelog)
  .filter((release) => !release.unreleased)
  .map((release) => {
    const entries = visibleGroups(release).flatMap((group) => group.entries);
    return {
      version: release.version,
      date: release.date,
      longDate: longDate(release.date),
      path: `/changelog/${release.version}/`,
      summary: release.summary
        ? {
            title: plain(release.summary.title),
            description: plain(release.summary.description),
            post: postText(release.summary),
          }
        : null,
      // The lead's first paragraph IS the summary, and the page sets it as the
      // headline and standfirst. Rendering it again in the notes would say it twice.
      html: renderHTML(release.summary ? { ...release, lead: release.lead.slice(1) } : release),
      highlights: entries.flatMap((entry) => (entry.headline ? [plain(entry.headline)] : [])),
      highlightsHtml: entries.flatMap((entry) => (entry.headline ? [inline(entry.headline)] : [])),
      card: release.version in cards ? `/changelog/${release.version}.png` : null,
    };
  });

/*
 * The nav's version badge links to the page for APP_VERSION, and nothing checks a
 * link at build time: a version bumped in config.ts ahead of its CHANGELOG
 * heading would put a 404 in the header of every page. CI already refuses a tag
 * the two disagree on; this refuses the build, which is earlier, and is also
 * true of a branch that is never tagged.
 */
if (!RELEASES.some((release) => release.version === APP_VERSION)) {
  throw new Error(
    `config.ts says APP_VERSION ${APP_VERSION}, and CHANGELOG.md has no \`## [${APP_VERSION}]\` section for the nav's version badge to link to`,
  );
}
