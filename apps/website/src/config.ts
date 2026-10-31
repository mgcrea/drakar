/**
 * Every fact the pages share lives here, and nowhere else.
 *
 * The repo is the authority on all of it. If something here disagrees with the
 * root README, SECURITY.md or apps/apple, the tree is right and this file is
 * stale.
 */

export const SITE_DOMAIN = "drakar.mgcrea.io";
export const SITE_URL = `https://${SITE_DOMAIN}`;

export const APP_NAME = "Drakar";
/** The release configuration's identifier (PRODUCT_BUNDLE_IDENTIFIER in apps/apple). */
export const BUNDLE_ID = "io.mgcrea.Drakar";

// <generated:version> generated from MARKETING_VERSION by `pnpm version:sync` — do not edit by hand
export const APP_VERSION = "1.1.0";
// </generated:version>

/** README's first sentence, word for word. */
export const TAGLINE =
  "A native macOS app to drive Claude Code: the conversation, the tool calls, the permission prompts and the diffs, in a window as light as Zed.";

/** The deployment target in apps/apple. */
export const MIN_MACOS = "macOS 26";

export const REPO_URL = "https://github.com/mgcrea/drakar";

export const DOCS = {
  security: `${REPO_URL}/blob/main/SECURITY.md`,
  audit: `${REPO_URL}/blob/main/scripts/audit-network.sh`,
  /** The repo's own licence: MIT, for the source. The signed build is under the EULA (/terms). */
  sourceLicense: `${REPO_URL}/blob/main/LICENSE`,
  ideBridge: `${REPO_URL}/blob/main/docs/claude-ide-bridge.md`,
} as const;

/**
 * Anthropic's own words on what Drakar does, quoted on the home page, and where
 * they are. Checked against the live page on 2026-10-21
 * (docs/marketing/competitive-brief-2026-10-21.md §2.1). If Anthropic rewords
 * it, the quote goes, not the link.
 */
export const ANTHROPIC_TERMS = {
  quote:
    "an end user… signing in to the unmodified Claude Code binary with their own Claude subscription",
  url: "https://code.claude.com/docs/en/legal-and-compliance",
} as const;

/**
 * The public tracker, the shared `mgcrea/support` repo's drakar folder: the same
 * `trackerURL` as apps/apple/Drakar/Services/Support.swift. `preferIssueTracker`
 * is true there, so /support/ leads with it.
 */
export const ISSUES_URL = "https://github.com/mgcrea/support/tree/main/drakar";
/**
 * A new issue, labelled for Drakar. Not `${ISSUES_URL}/issues/new`: that is
 * `…/tree/main/drakar/issues/new`, a 404.
 */
export const GITHUB_NEW_ISSUE_URL =
  "https://github.com/mgcrea/support/issues/new?labels=drakar&title=%5Bdrakar%5D+";

/**
 * This project's slug in the shared feedback contract: the site's subdomain, which
 * is what the Worker accepts from this origin (contract 0.4.0), and
 * `SupportApp(slug:)` in Support.swift. `feedback:check` asserts the first.
 */
export const APP_SLUG = "drakar";

/**
 * The feedback Worker's origin, shared by every mgcrea site. It has to be in
 * `connect-src` (astro.config.mjs), or the browser refuses the form's POST with
 * no build error. `pnpm feedback:check` asserts it survives into the policy.
 */
export const FEEDBACK_API = "https://feedback.mgcrea.io";

/** The feedback form on this site; Support.swift's Send Feedback lands here. */
export const FEEDBACK_URL = "/feedback/";

/** The account X attributes the cards to. */
export const X_HANDLE = "@mgcrea";

/** The vanity paths public/_redirects serves. */
export const DOWNLOAD = {
  zip: "/download",
  checksum: "/checksum",
  releases: "/releases",
  appcast: `${SITE_DOMAIN}/appcast.xml`,
  requires: `${MIN_MACOS} or later`,
} as const;

export const SUPPORT_EMAIL = "support@mgcrea.io";
export const SUPPORT_EMAIL_HREF = `mailto:${SUPPORT_EMAIL}`;
export const SECURITY_EMAIL = "security@mgcrea.io";
export const SECURITY_EMAIL_HREF = `mailto:${SECURITY_EMAIL}`;

/**
 * Whether /buy resolves to a live payment link.
 *
 * The website's mirror of `LicenceLinks.isSelling` in apps/apple: the two move
 * together, in the release that opens the store. It gates the price and the Buy
 * button on the home page and the prose that says whether anything is on sale, on
 * /terms and /privacy.
 */
export const SELLING = true;

/**
 * The evaluation window: started from a button, never armed on its own, and held
 * in memory rather than written to disk (`Trial.duration` in apps/apple).
 */
export const TRIAL = { minutes: 30 } as const;

/**
 * The price, as it is charged. Two currencies, both set explicitly on the Stripe
 * price via `currency_options`, never one converted from the other, the way
 * armada, bastion and cupertino sell. The USD figure is quoted tax-exclusive and
 * the EUR figure VAT-inclusive, the ordinary convention on each side, so the page
 * shows both rather than picking one.
 *
 * public/llms.txt repeats this and TRIAL by hand, as prose: a price, a refund
 * window or a trial length changed here is a second edit there.
 */
export const PRICING = {
  price: "$14.99",
  /** What the JSON-LD offer carries. */
  amount: "14.99",
  currency: "USD",
  eur: "€14.99",
  /** The stable vanity URL: a 302 in public/_redirects to the live Stripe payment link. */
  buy: "/buy",
  /** Written as a fragment, so a call site capitalises it where a sentence starts. */
  covers: "every 1.x release, on every Mac you own",
  refundDays: 30,
} as const;

/**
 * The og:image card. `pnpm icons` bakes these lines into `og-image.png`, so
 * editing them here is only half the change: re-run it, or the picture and the
 * page disagree. Both lines are a fixed size, centred, with no wrap: keep them short.
 */
export const SOCIAL_CARD = {
  headline: "Claude Code and Codex, in a native Mac window",
  subhead: "Your installed CLIs · the diffs · an editor beside them",
  alt: "The Drakar icon, two glass sails on a blue-to-violet plate, above the word Drakar, the line “Claude Code and Codex, in a native Mac window”, and “Your installed CLIs · the diffs · an editor beside them”.",
  width: 1200,
  height: 630,
} as const;

/**
 * The sibling apps given a card on the home page. Neither pitch claims the apps
 * work together: nothing in any repo documents an integration. What is true is
 * that all three are Mac apps for people who work with agents, sold the same way.
 *
 * The icons are the siblings' own `public/app-icon.svg`, copied into
 * `public/apps/`, because `img-src 'self'` blocks a hotlink silently. Nothing
 * keeps the copies fresh; the fleet survey's `sibling-stale` says when one is old.
 */
export const SIBLING_APPS = [
  {
    name: "Armada",
    tagline: "Every agent session, one window that knows.",
    pitch:
      "A menu bar app that watches every Claude Code, Codex and Grok Build session on your Mac, across accounts: which one is waiting on you, how full its context is, and how much of each plan is left.",
    url: "https://armada.mgcrea.io",
    icon: "/apps/armada.svg",
  },
  {
    name: "Bastion",
    tagline: "One MCP server, running once.",
    pitch:
      "A menu bar app that supervises the MCP servers your agents connect to: one process per profile instead of one per editor, credentials in the Keychain, and every tool call recorded.",
    url: "https://bastion.mgcrea.io",
    icon: "/apps/bastion.svg",
  },
] as const;

/**
 * The footer's More apps: three, the ones a Drakar reader plausibly also wants.
 * Not the whole fleet, which between thirteen subdomains reads as a link farm.
 */
export const FOOTER_APPS = [
  {
    name: "Armada",
    blurb: "Every agent session and plan limit, from the menu bar.",
    url: "https://armada.mgcrea.io",
  },
  {
    name: "Bastion",
    blurb: "One supervised MCP process per profile, credentials in the Keychain.",
    url: "https://bastion.mgcrea.io",
  },
  {
    name: "Cupertino",
    blurb: "Your Apple apps as MCP servers, behind one Full Disk Access grant.",
    url: "https://cupertino.mgcrea.io",
  },
] as const;
